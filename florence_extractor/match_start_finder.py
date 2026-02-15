#!/usr/bin/env python3
"""
Match Start Finder - Efficiently finds match start timestamps (0:0 sets, 0:0 game)
in table tennis video streams using a multi-phase search strategy.

Strategy:
1. Coarse Scan: Sample every 3 minutes to identify active match regions
2. Binary Search: Find exact match start transitions (no-score → 0:0)
3. In-Match Detection: Find new game starts within matches
4. Retry Logic: Handle frames without score overlay

Usage:
    # Local video
    python match_start_finder.py --local_video "/path/to/video.mp4"

    # YouTube video (downloads first, then processes)
    python match_start_finder.py --youtube_video "https://youtube.com/watch?v=..."

    # With backend selection
    python match_start_finder.py --local_video "/path/to/video.mp4" --backend openvino
"""

from transformers import AutoProcessor, AutoModelForCausalLM
from PIL import Image
import cv2
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import shutil
import time
import traceback
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, List, Tuple
from unittest.mock import MagicMock

# Mock flash_attn to avoid installation requirement
mock_flash_attn = MagicMock()
mock_flash_attn.__spec__ = MagicMock()
sys.modules["flash_attn"] = mock_flash_attn


# Configuration for cropping (same as score_extractor.py)
BOTTOM_PERCENT = 0.14  # Fraction of height to crop from the bottom
LEFT_PERCENT = 0.40    # Fraction of width to crop from the left

# Search strategy parameters
COARSE_INTERVAL_SECONDS = 180  # 3 minutes between coarse samples
BINARY_SEARCH_PRECISION = 10   # Stop binary search when interval < 10 seconds
MAX_RETRIES_PER_TIMESTAMP = 3  # Max retries for empty frames
RETRY_OFFSET_SECONDS = 5       # Offset for retry attempts
MIN_BREAK_DURATION = 300       # Minimum 5 minutes break between matches
# Max points to consider as "early match" - covers most of first game
MAX_EARLY_GAME_POINTS = 15
# Seconds per point for approximation (used to calculate offset)
SECONDS_PER_POINT = 16


@dataclass
class ScoreResult:
    """Represents the result of score extraction from a frame."""
    success: bool
    player1: str = ""
    player2: str = ""
    set1: int = -1
    set2: int = -1
    game1: int = -1
    game2: int = -1
    error: str = ""

    def is_match_start(self) -> bool:
        """Check if this is a match start (0:0 sets, 0:0 game)."""
        return (self.success and
                self.set1 == 0 and self.set2 == 0 and
                self.game1 == 0 and self.game2 == 0)

    def is_game_start(self) -> bool:
        """Check if this is a game start (0:0 game, any set score)."""
        return self.success and self.game1 == 0 and self.game2 == 0

    def is_early_match(self) -> bool:
        """Check if this is early in the first game (sets 0:0, few points)."""
        if not self.success:
            return False
        # Sets must be 0:0 (first game of match)
        if self.set1 != 0 or self.set2 != 0:
            return False
        # Total points must be low (1:0, 0:1, 2:0, 0:2, 1:1, 2:1, etc)
        return self.total_points() <= MAX_EARLY_GAME_POINTS

    def total_points(self) -> int:
        """Return total points in current game."""
        if not self.success:
            return -1
        return self.game1 + self.game2


@dataclass
class MatchStart:
    """Represents a found match start."""
    timestamp_seconds: float
    timestamp_formatted: str
    player1: str
    player2: str
    image_path: str


def format_timestamp(seconds: float) -> str:
    """Convert seconds to HH:MM:SS format."""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def get_video_duration(video_path: str) -> float:
    """Get video duration in seconds using ffprobe."""
    cmd = [
        'ffprobe', '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        video_path
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True)
        return float(result.stdout.strip())
    except (subprocess.CalledProcessError, ValueError) as e:
        print(f"Error getting video duration: {e}")
        return 0


def extract_frame(video_path: str, timestamp_seconds: float, output_path: str) -> bool:
    """Extract a single frame from video at given timestamp."""
    timestamp_str = format_timestamp(timestamp_seconds)
    cmd = [
        'ffmpeg', '-y', '-ss', timestamp_str,
        '-i', video_path,
        '-frames:v', '1',
        '-q:v', '2',
        output_path
    ]
    try:
        subprocess.run(cmd, capture_output=True, check=True)
        return os.path.exists(output_path)
    except subprocess.CalledProcessError:
        return False


def crop_image(image_path: str) -> Optional[Image.Image]:
    """Crop the score region from an image (bottom-left corner)."""
    try:
        img = cv2.imread(image_path)
        if img is None:
            return None

        h, w = img.shape[:2]
        y_start = int(h * (1 - BOTTOM_PERCENT))
        x_end = int(w * LEFT_PERCENT)

        cropped = img[y_start:h, 0:x_end]
        # Convert BGR to RGB for PIL
        cropped_rgb = cv2.cvtColor(cropped, cv2.COLOR_BGR2RGB)
        return Image.fromarray(cropped_rgb)
    except Exception as e:
        print(f"Error cropping image: {e}")
        return None


# Backend constants
BACKEND_PYTORCH = "pytorch-cpu"
BACKEND_OPENVINO = "openvino"
ALL_BACKENDS = [BACKEND_PYTORCH, BACKEND_OPENVINO]


def get_default_backend() -> str:
    """Get default backend - use openvino if available, else pytorch."""
    try:
        import openvino  # noqa: F401
        return BACKEND_OPENVINO
    except ImportError:
        return BACKEND_PYTORCH


class ScoreExtractor:
    """Handles score extraction using Florence-2 OCR model."""

    def __init__(self, backend: str = None):
        self.model = None
        self.processor = None
        self.device = "cpu"
        self._initialized = False
        self._backend = backend or get_default_backend()
        self._ov_model = None  # For OpenVINO backend

    def initialize(self) -> bool:
        """Load the Florence-2 model using selected backend."""
        if self._initialized:
            return True

        script_dir = os.path.dirname(os.path.abspath(__file__))
        self._model_path = os.path.join(
            script_dir, "florence2-tt-finetuned")

        if self._backend == BACKEND_OPENVINO:
            return self._initialize_openvino()
        else:
            return self._initialize_pytorch()

    def _initialize_pytorch(self) -> bool:
        """Initialize PyTorch backend (original working code)."""
        print("Loading Florence-2 model (PyTorch CPU)...")
        try:
            self.processor = AutoProcessor.from_pretrained(
                self._model_path, trust_remote_code=True)
            self.model = AutoModelForCausalLM.from_pretrained(
                self._model_path, trust_remote_code=True,
                attn_implementation="eager").to(self.device)
            self._initialized = True
            print("Model loaded successfully.")
            return True
        except Exception as e:
            print(f"Error loading Florence-2 model: {e}")
            return False

    def _initialize_openvino(self) -> bool:
        """Initialize OpenVINO backend for GPU acceleration."""
        print("Loading Florence-2 model (OpenVINO GPU)...")
        try:
            from backends.ov_florence2_helper import (
                OVFlorence2Model
            )
            from pathlib import Path

            ov_model_dir = Path(self._model_path) / "openvino"

            # Load processor (same as PyTorch)
            self.processor = AutoProcessor.from_pretrained(
                ov_model_dir, trust_remote_code=True)

            # Load OpenVINO model (raises FileNotFoundError if not converted)
            self._ov_model = OVFlorence2Model(
                ov_model_dir, device="GPU", ov_config={})

            self._initialized = True
            print("Model loaded successfully (OpenVINO GPU).")
            return True
        except FileNotFoundError as e:
            print(f"Error: {e}")
            return False
        except Exception as e:
            print(f"Error loading OpenVINO model: {e}")
            print("Falling back to PyTorch...")
            self._backend = BACKEND_PYTORCH
            return self._initialize_pytorch()

    def extract_score(self, pil_image: Image.Image) -> ScoreResult:
        """Extract score from a cropped PIL image."""
        if not self._initialized:
            return ScoreResult(success=False, error="Model not initialized")

        try:
            if self._backend == BACKEND_OPENVINO:
                generated_text = self._extract_openvino(pil_image)
            else:
                generated_text = self._extract_pytorch(pil_image)

            return self._parse_score(generated_text)
        except Exception as e:
            return ScoreResult(success=False, error=str(e))

    def _extract_pytorch(self, pil_image: Image.Image) -> str:
        """Extract text using PyTorch backend (original working code)."""
        prompt = "<OCR>"
        inputs = self.processor(
            text=prompt, images=pil_image,
            return_tensors="pt").to(self.device)

        generated_ids = self.model.generate(
            input_ids=inputs["input_ids"],
            pixel_values=inputs["pixel_values"],
            max_new_tokens=1024,
            num_beams=1,
            do_sample=False,
            use_cache=False
        )
        return self.processor.batch_decode(
            generated_ids, skip_special_tokens=True)[0]

    def _extract_openvino(self, pil_image: Image.Image) -> str:
        """Extract text using OpenVINO backend (GPU accelerated)."""
        prompt = "<OCR>"
        inputs = self.processor(
            text=prompt, images=pil_image, return_tensors="pt")

        generated_ids = self._ov_model.generate(
            input_ids=inputs["input_ids"],
            pixel_values=inputs["pixel_values"],
            max_new_tokens=1024,
            num_beams=1,
            do_sample=False
        )
        return self.processor.batch_decode(
            generated_ids, skip_special_tokens=True)[0]

    def _parse_score(self, text: str) -> ScoreResult:
        """Parse Florence-2 output to extract score data."""
        # Pattern: row 1: PLAYER, SET, GAME row 2: PLAYER, SET, GAME
        pattern = r"row 1:\s*(.*?),\s*(\d+)(?:[,.\s/&-]+| and )(\d+)\s*row 2:\s*(.*?),\s*(\d+)(?:[,.\s/&-]+| and )(\d+)"
        match = re.search(pattern, text)

        if match:
            return ScoreResult(
                success=True,
                player1=match.group(1).strip(),
                set1=int(match.group(2)),
                game1=int(match.group(3)),
                player2=match.group(4).strip(),
                set2=int(match.group(5)),
                game2=int(match.group(6))
            )
        else:
            return ScoreResult(success=False, error=f"Could not parse: '{text}'")


class MatchStartFinder:
    """Main class implementing the multi-phase search strategy."""

    def __init__(self, video_path: str, output_dir: str, backend: str = None,
                 keep_cropped: bool = False):
        self.video_path = video_path
        self.output_dir = output_dir
        self.extractor = ScoreExtractor(backend=backend)
        self.temp_dir = tempfile.mkdtemp(prefix="match_finder_")
        self.ocr_calls = 0
        self.found_matches: List[MatchStart] = []
        self.keep_cropped = keep_cropped
        self.cropped_dir = None
        if keep_cropped:
            self.cropped_dir = os.path.join(output_dir, "cropped_frames")
            os.makedirs(self.cropped_dir, exist_ok=True)

    def cleanup(self):
        """Remove temporary directory."""
        if os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir)

    def _get_temp_image_path(self, timestamp: float) -> str:
        """Generate a temporary image path for a timestamp."""
        return os.path.join(self.temp_dir, f"frame_{timestamp:.1f}.jpg")

    def _extract_and_analyze(self, timestamp: float,
                             retry: int = 0) -> Tuple[ScoreResult, str]:
        """Extract frame and analyze score with retry logic."""
        actual_timestamp = timestamp + (retry * RETRY_OFFSET_SECONDS)
        image_path = self._get_temp_image_path(actual_timestamp)

        if not extract_frame(self.video_path, actual_timestamp, image_path):
            return ScoreResult(success=False, error="Frame extraction failed"), ""

        cropped = crop_image(image_path)
        if cropped is None:
            return ScoreResult(success=False, error="Image cropping failed"), ""

        # Save cropped image if --keep_cropped is enabled
        if self.keep_cropped and self.cropped_dir:
            unique_id = str(uuid.uuid4())
            cropped_path = os.path.join(
                self.cropped_dir,
                f"cropped_{actual_timestamp:.1f}-{unique_id}.jpg")
            cropped.save(cropped_path)

        self.ocr_calls += 1
        result = self.extractor.extract_score(cropped)
        return result, image_path

    def _analyze_with_retry(self, timestamp: float) -> Tuple[ScoreResult, str, float]:
        """Analyze timestamp with retry logic for empty frames."""
        for retry in range(MAX_RETRIES_PER_TIMESTAMP):
            actual_ts = timestamp + (retry * RETRY_OFFSET_SECONDS)
            result, image_path = self._extract_and_analyze(timestamp, retry)

            if result.success:
                return result, image_path, actual_ts

            # Try negative offset on second retry
            if retry == 1:
                actual_ts = timestamp - RETRY_OFFSET_SECONDS
                result, image_path = self._extract_and_analyze(
                    timestamp - RETRY_OFFSET_SECONDS, 0)
                if result.success:
                    return result, image_path, actual_ts
        return ScoreResult(success=False, error="All retries failed"), "", timestamp

    def _save_match_image(self, temp_path: str, timestamp: float,
                          player1: str, player2: str) -> str:
        """Save match start image to output directory."""
        # Clean player names for filename
        p1_clean = re.sub(r'[^\w\-]', '_', player1)[:20]
        p2_clean = re.sub(r'[^\w\-]', '_', player2)[:20]
        ts_str = format_timestamp(timestamp).replace(':', '-')

        filename = f"match_{ts_str}_{p1_clean}_vs_{p2_clean}.jpg"
        output_path = os.path.join(self.output_dir, filename)

        shutil.copy2(temp_path, output_path)
        return output_path

    def _binary_search_match_start(self, start_ts: float, end_ts: float) -> Optional[MatchStart]:
        """
        Binary search to find exact match start between two timestamps.
        If 0:0 is not found, falls back to early match scores (1:0, 0:1, etc.)
        and subtracts EARLY_MATCH_OFFSET seconds as approximation.

        start_ts: Last known no-score or previous match timestamp
        end_ts: First known score visible timestamp
        """
        print(
            f"  Binary search between {format_timestamp(start_ts)} "
            f"and {format_timestamp(end_ts)}")

        best_match: Optional[MatchStart] = None
        # Track earliest early match as fallback
        earliest_early_match: Optional[Tuple[float, ScoreResult, str]] = None

        while (end_ts - start_ts) > BINARY_SEARCH_PRECISION:
            mid_ts = (start_ts + end_ts) / 2
            result, image_path, actual_ts = self._analyze_with_retry(mid_ts)

            if result.success:
                if result.is_match_start():
                    # Found a 0:0 score, search earlier for the earliest one
                    best_match = MatchStart(
                        timestamp_seconds=actual_ts,
                        timestamp_formatted=format_timestamp(actual_ts),
                        player1=result.player1,
                        player2=result.player2,
                        image_path=image_path
                    )
                    end_ts = mid_ts
                elif result.is_early_match():
                    # Early match score (1:0, 0:1, etc) - track as fallback
                    if (earliest_early_match is None or
                            actual_ts < earliest_early_match[0]):
                        earliest_early_match = (actual_ts, result, image_path)
                    end_ts = mid_ts
                elif result.total_points() > 0 or result.set1 > 0 or result.set2 > 0:
                    # Score already progressed, match start is earlier
                    end_ts = mid_ts
                else:
                    # Something unexpected, continue searching
                    start_ts = mid_ts
            else:
                # No score visible, match start is later
                start_ts = mid_ts

        # If no exact 0:0 found, use early match with offset
        if best_match is None and earliest_early_match is not None:
            early_ts, early_result, early_image = earliest_early_match
            # Calculate offset based on points played
            points = early_result.total_points()
            offset = points * SECONDS_PER_POINT
            approx_ts = max(0, early_ts - offset)
            print(f"    Using early score {early_result.game1}:"
                  f"{early_result.game2} at {format_timestamp(early_ts)}, "
                  f"approximating start at {format_timestamp(approx_ts)} "
                  f"(-{offset}s for {points} points)")
            best_match = MatchStart(
                timestamp_seconds=approx_ts,
                timestamp_formatted=format_timestamp(approx_ts),
                player1=early_result.player1,
                player2=early_result.player2,
                image_path=early_image
            )

        return best_match

    def _search_backward_for_game_starts(self, timestamp: float,
                                         current_score: ScoreResult) -> List[MatchStart]:
        """Search backward from a non-zero score to find game starts."""
        game_starts = []

        # Estimate time to go back based on current game score
        # ~16 seconds per point
        points_played = current_score.total_points()
        estimated_game_time = points_played * 16 + 30  # Add buffer

        search_start = max(0, timestamp - estimated_game_time)

        result, image_path, actual_ts = self._analyze_with_retry(search_start)

        if result.success and result.is_game_start():
            # Check if it's also a match start (0:0 sets)
            if result.is_match_start():
                game_starts.append(MatchStart(
                    timestamp_seconds=actual_ts,
                    timestamp_formatted=format_timestamp(actual_ts),
                    player1=result.player1,
                    player2=result.player2,
                    image_path=image_path
                ))

        return game_starts

    def find_match_starts(self) -> List[MatchStart]:
        """
        Main method to find all match starts in the video.
        Implements the multi-phase search strategy.
        """
        total_start_time = time.time()

        if not self.extractor.initialize():
            print("Failed to initialize score extractor")
            return []

        duration = get_video_duration(self.video_path)
        if duration <= 0:
            print("Could not determine video duration")
            return []

        print(
            f"\nVideo duration: {format_timestamp(duration)} "
            f"({duration:.0f} seconds)")
        print(f"Using coarse interval: {COARSE_INTERVAL_SECONDS} seconds")

        # Phase 1: Coarse scan
        phase1_start = time.time()
        print(f"\n=== Phase 1: Coarse Scan ===")
        print(f"Started at: {datetime.now().strftime('%H:%M:%S')}")
        coarse_samples: List[Tuple[float, ScoreResult, str]] = []

        timestamp = 0
        while timestamp < duration:
            print(f"  Sampling at {format_timestamp(timestamp)}...", end=" ")
            result, image_path, actual_ts = self._analyze_with_retry(timestamp)

            if result.success:
                print(f"Score: {result.player1} {result.set1}:{result.set2} {result.player2}, "
                      f"Game: {result.game1}:{result.game2}")

                # Check if this is already a match start
                if result.is_match_start():
                    print(
                        f"    → Found match start at {format_timestamp(actual_ts)}")
                    saved_path = self._save_match_image(
                        image_path, actual_ts, result.player1, result.player2)
                    self.found_matches.append(MatchStart(
                        timestamp_seconds=actual_ts,
                        timestamp_formatted=format_timestamp(actual_ts),
                        player1=result.player1,
                        player2=result.player2,
                        image_path=saved_path
                    ))
            else:
                print(f"No score: {result.error}")

            coarse_samples.append((actual_ts, result, image_path))
            timestamp += COARSE_INTERVAL_SECONDS

        phase1_duration = time.time() - phase1_start
        print(f"Phase 1 completed in {phase1_duration:.1f} seconds")

        # Phase 2: Find transitions and binary search
        phase2_start = time.time()
        print(f"\n=== Phase 2: Binary Search for Match Starts ===")
        print(f"Started at: {datetime.now().strftime('%H:%M:%S')}")

        for i in range(1, len(coarse_samples)):
            prev_ts, prev_result, _ = coarse_samples[i - 1]
            curr_ts, curr_result, curr_image = coarse_samples[i]

            # Detect transition: no score → score visible
            # Only consider it a real match break if gap >= MIN_BREAK_DURATION
            # or if we have consecutive no-score samples before this
            if not prev_result.success and curr_result.success:
                # Calculate duration of no-score period
                no_score_start = prev_ts
                for j in range(i - 2, -1, -1):
                    if not coarse_samples[j][1].success:
                        no_score_start = coarse_samples[j][0]
                    else:
                        break
                no_score_duration = curr_ts - no_score_start

                if no_score_duration < MIN_BREAK_DURATION:
                    print(f"\n  Skipping short gap at {format_timestamp(prev_ts)} "
                          f"({no_score_duration:.0f}s < {MIN_BREAK_DURATION}s)")
                    continue

                print(f"\nTransition detected between "
                      f"{format_timestamp(no_score_start)} and "
                      f"{format_timestamp(curr_ts)} "
                      f"(break: {no_score_duration:.0f}s)")

                match_start = self._binary_search_match_start(
                    no_score_start, curr_ts)
                if match_start and not self._is_duplicate(match_start):
                    saved_path = self._save_match_image(
                        match_start.image_path, match_start.timestamp_seconds,
                        match_start.player1, match_start.player2)
                    match_start.image_path = saved_path
                    self.found_matches.append(match_start)
                    print(
                        f"  → Confirmed match start at "
                        f"{match_start.timestamp_formatted}")

            # Detect player change (different match, same visibility)
            elif (prev_result.success and curr_result.success and
                  self._players_changed(prev_result, curr_result)):
                print(f"\nPlayer change detected between "
                      f"{format_timestamp(prev_ts)} and "
                      f"{format_timestamp(curr_ts)}")

                match_start = self._binary_search_match_start(prev_ts, curr_ts)
                if match_start and not self._is_duplicate(match_start):
                    saved_path = self._save_match_image(
                        match_start.image_path, match_start.timestamp_seconds,
                        match_start.player1, match_start.player2)
                    match_start.image_path = saved_path
                    self.found_matches.append(match_start)
                    print(
                        f"  → Confirmed match start at "
                        f"{match_start.timestamp_formatted}")

            # Detect score reset (set count decreased = new match)
            elif (prev_result.success and curr_result.success and
                  self._score_reset_detected(prev_result, curr_result)):
                print(f"\nScore reset detected between {format_timestamp(prev_ts)} "
                      f"and {format_timestamp(curr_ts)}")

                match_start = self._binary_search_match_start(prev_ts, curr_ts)
                if match_start and not self._is_duplicate(match_start):
                    saved_path = self._save_match_image(
                        match_start.image_path, match_start.timestamp_seconds,
                        match_start.player1, match_start.player2)
                    match_start.image_path = saved_path
                    self.found_matches.append(match_start)
                    print(
                        f"  → Confirmed match start at {match_start.timestamp_formatted}")

        # Sort matches by timestamp
        self.found_matches.sort(key=lambda m: m.timestamp_seconds)

        phase2_duration = time.time() - phase2_start
        print(f"Phase 2 completed in {phase2_duration:.1f} seconds")

        total_duration = time.time() - total_start_time
        print("\n=== Summary ===")
        print(f"Total OCR calls: {self.ocr_calls}")
        print(f"Phase 1 (Coarse Scan): {phase1_duration:.1f} seconds")
        print(f"Phase 2 (Binary Search): {phase2_duration:.1f} seconds")
        print(f"Total time: {total_duration:.1f} seconds")
        print(f"Match starts found: {len(self.found_matches)}")

        return self.found_matches

    def _is_duplicate(self, match: MatchStart) -> bool:
        """Check if match start already found (within MIN_BREAK_DURATION)."""
        for existing in self.found_matches:
            if abs(existing.timestamp_seconds - match.timestamp_seconds) < MIN_BREAK_DURATION:
                return True
        return False

    def _players_changed(self, prev: ScoreResult, curr: ScoreResult) -> bool:
        """Check if players changed between two samples."""
        def normalize(name: str) -> str:
            return re.sub(r'[^A-Z0-9]', '', name.upper())

        prev_players = {normalize(prev.player1), normalize(prev.player2)}
        curr_players = {normalize(curr.player1), normalize(curr.player2)}

        # Players changed if the sets are different
        return prev_players != curr_players

    def _score_reset_detected(self, prev: ScoreResult, curr: ScoreResult) -> bool:
        """Check if score was reset (new match started)."""
        # Total sets decreased = new match
        prev_total = prev.set1 + prev.set2
        curr_total = curr.set1 + curr.set2

        return curr_total < prev_total


def extract_video_id(youtube_url: str) -> str:
    """
    Extract video ID from YouTube URL.

    Supports formats:
    - https://www.youtube.com/watch?v=i8OS-w44mrQ
    - https://youtu.be/i8OS-w44mrQ
    - https://www.youtube.com/live/i8OS-w44mrQ

    Returns:
        Video ID string (e.g., 'i8OS-w44mrQ')
    """
    if 'watch?v=' in youtube_url:
        video_id = youtube_url.split('watch?v=')[-1].split('&')[0]
    elif 'youtu.be/' in youtube_url:
        video_id = youtube_url.split('youtu.be/')[-1].split('?')[0]
    elif '/live/' in youtube_url:
        video_id = youtube_url.split('/live/')[-1].split('?')[0]
    else:
        # Fallback: try to get last path segment
        video_id = youtube_url.rstrip('/').split('/')[-1].split('?')[0]

    return video_id


def get_video_info(youtube_url: str) -> Tuple[Optional[str], Optional[str]]:
    """
    Fetch video title and upload date from YouTube using yt-dlp.

    Returns:
        Tuple of (title, upload_date) where upload_date is in YYYYMMDD format.
        Either value can be None if fetch failed.
    """
    try:
        import yt_dlp
    except ImportError:
        print("Error: yt-dlp not installed. Run: pip install yt-dlp")
        return None, None

    ydl_opts = {
        'quiet': True,
        'no_warnings': True,
        'skip_download': True,
        'extractor_args': {'youtubetab': ['approximate_date']},
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(youtube_url, download=False)
            title = info.get('title')
            upload_date = info.get('upload_date')  # Format: YYYYMMDD
            return title, upload_date
    except Exception as e:
        print(f"Warning: Could not fetch video info: {e}")
        return None, None


def download_youtube_video(youtube_url: str, output_dir: str) -> Optional[str]:
    """
    Download YouTube video at 480p (video only, no audio).

    Returns:
        Path to downloaded video file, or None if failed.
    """
    try:
        import yt_dlp
    except ImportError:
        print("Error: yt-dlp not installed. Run: pip install yt-dlp")
        return None

    # Extract video ID for filename
    video_id = extract_video_id(youtube_url)
    video_path = os.path.join(output_dir, f"{video_id}.webm")

    # Skip if already downloaded
    if os.path.exists(video_path):
        print(f"Video already downloaded: {video_path}")
        return video_path

    ydl_opts = {
        'format': 'bv*[height<=480]',  # Video only, no audio
        'outtmpl': video_path,
        'quiet': False,
        'no_warnings': False,
    }

    print(f"Downloading YouTube video at 480p (video only)...")
    print(f"  URL: {youtube_url}")
    start_time = time.time()

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([youtube_url])

        download_time = time.time() - start_time

        if os.path.exists(video_path):
            file_size = os.path.getsize(video_path) / (1024 * 1024)
            print(f"Download complete: {video_path}")
            print(f"  Size: {file_size:.1f} MB")
            print(f"  Time: {download_time:.1f}s")
            return video_path
        else:
            # Check for alternative extension
            for ext in ['.mp4', '.mkv', '.webm']:
                alt_path = video_path.rsplit('.', 1)[0] + ext
                if os.path.exists(alt_path):
                    return alt_path
            print("Error: Video file not found after download.")
            return None

    except Exception as e:
        print(f"Error downloading video: {e}")
        traceback.print_exc()
        return None


def main():
    parser = argparse.ArgumentParser(
        description='Find match start timestamps in table tennis videos')
    # Video source (mutually exclusive)
    video_group = parser.add_mutually_exclusive_group(required=True)
    video_group.add_argument(
        '--local_video', type=str,
        help='Path to a local video file (requires --video_id and --video_title)')
    video_group.add_argument(
        '--youtube_video', type=str,
        help='YouTube video URL (will be downloaded first)')

    # Video metadata (required for local videos)
    parser.add_argument('--video_id', type=str, default=None,
                        help='Video ID (required when using --local_video)')
    parser.add_argument('--video_title', type=str, default=None,
                        help='Video title (required when using --local_video)')

    parser.add_argument('--output', type=str, default='match_starts',
                        help='Output directory (default: match_starts)')
    parser.add_argument('--backend', type=str, default=None,
                        choices=ALL_BACKENDS,
                        help='Inference backend: pytorch-cpu or openvino')
    parser.add_argument('--keep_cropped', action='store_true',
                        help='Save cropped score images to cropped_frames/')
    parser.add_argument('--output_json_file', type=str, default=None,
                        help='Path to output JSON file with match data')
    parser.add_argument('--only_extract_video_metadata', action='store_true',
                        help='Only extract video metadata (id, title, upload_date) '
                             'without running match detection')
    args = parser.parse_args()

    # Validate that --video_id and --video_title are provided for local videos
    if args.local_video:
        if not args.video_id:
            parser.error("--video_id is required when using --local_video")
        if not args.video_title:
            parser.error("--video_title is required when using --local_video")

    # Create output directory
    os.makedirs(args.output, exist_ok=True)

    # Variables for video metadata
    video_id = None
    video_title = None
    upload_date = None  # Format: YYYYMMDD

    # Determine video path
    video_path = None
    if args.local_video:
        if not os.path.exists(args.local_video):
            print(f"Error: Video file not found: {args.local_video}")
            sys.exit(1)
        video_path = args.local_video
        video_id = args.video_id
        video_title = args.video_title
        print(f"Using local video: {video_path}")
        print(f"Video ID: {video_id}")
        print(f"Video Title: {video_title}")
    else:
        # Extract video_id and fetch video info for YouTube videos
        video_id = extract_video_id(args.youtube_video)
        print(f"Video ID: {video_id}")

        print("Fetching video info...")
        video_title, upload_date = get_video_info(args.youtube_video)
        if video_title:
            print(f"Video Title: {video_title}")
        else:
            print("Warning: Could not fetch video title")
        if upload_date:
            print(f"Upload Date: {upload_date}")
        else:
            print("Warning: Could not fetch upload date")

        # If only extracting metadata, output and exit early
        if args.only_extract_video_metadata:
            print("\n=== Video Metadata ===")
            print(f"Video ID:    {video_id}")
            print(f"Title:       {video_title}")
            print(f"Upload Date: {upload_date}")
            if args.output_json_file:
                json_data = {
                    "video_id": video_id,
                    "video_title": video_title,
                    "upload_date": upload_date,
                    "matches": []
                }
                with open(args.output_json_file, 'w') as f:
                    json.dump(json_data, f, indent=2)
                print(f"\nJSON output written to: {args.output_json_file}")
            sys.exit(0)

        # Download YouTube video
        video_path = download_youtube_video(args.youtube_video, args.output)
        if not video_path:
            print("Failed to download YouTube video.")
            sys.exit(1)

    # Determine backend
    backend = args.backend or get_default_backend()

    print(f"\n{'=' * 60}")
    print("Match Start Finder")
    print('=' * 60)
    print(f"Video: {video_path}")
    print(f"Output directory: {args.output}")
    print(f"Backend: {backend}")
    print('=' * 60)

    finder = MatchStartFinder(video_path, args.output, backend=backend,
                              keep_cropped=args.keep_cropped)

    try:
        matches = finder.find_match_starts()

        if matches:
            print("\n" + "=" * 60)
            print("FOUND MATCH STARTS:")
            print("=" * 60)
            for i, match in enumerate(matches, 1):
                print(f"\nMatch {i}:")
                print(f"  Timestamp: {match.timestamp_formatted}")
                print(f"  Player 1:  {match.player1}")
                print(f"  Player 2:  {match.player2}")
                print(f"  Image:     {match.image_path}")

            # Write JSON output if requested
            if args.output_json_file:
                json_data = {
                    "video_id": video_id,
                    "video_title": video_title,
                    "upload_date": upload_date,  # Format: YYYYMMDD
                    "matches": [
                        {
                            "timestamp": int(m.timestamp_seconds),
                            "player1": m.player1,
                            "player2": m.player2
                        }
                        for m in matches
                    ]
                }
                with open(args.output_json_file, 'w') as f:
                    json.dump(json_data, f, indent=2)
                print(f"\nJSON output written to: {args.output_json_file}")
        else:
            print("\nNo match starts found.")
    finally:
        finder.cleanup()


if __name__ == "__main__":
    main()
