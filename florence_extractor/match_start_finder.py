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

from ocr_utils import parse_score, ScoreResult, normalize_text, is_similar
import argparse
import json
import os
import re
import subprocess
import sys
from wtt_video_processor import WttVideoProcessor
from prod_video_processor import ProdWttVideoProcessor
from test_video_processor import TestWttVideoProcessor
from prod_video_processor import ALL_BACKENDS, BACKEND_PYTORCH, BACKEND_OPENVINO, get_default_backend, get_device
import tempfile
import shutil
import time
import traceback
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, List, Tuple
from unittest.mock import MagicMock

# Add script directory to path for imports
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)


# Configuration for cropping (same as score_extractor.py)
BOTTOM_PERCENT = 0.14  # Fraction of height to crop from the bottom
LEFT_PERCENT = 0.40    # Fraction of width to crop from the left


def levenshtein_distance(s1: str, s2: str) -> int:
    """Calculate Levenshtein (edit) distance between two strings."""
    if len(s1) < len(s2):
        return levenshtein_distance(s2, s1)

    if len(s2) == 0:
        return len(s1)

    previous_row = range(len(s2) + 1)
    for i, c1 in enumerate(s1):
        current_row = [i + 1]
        for j, c2 in enumerate(s2):
            # j+1 instead of j since previous_row and current_row are 1 longer
            insertions = previous_row[j + 1] + 1
            deletions = current_row[j] + 1
            substitutions = previous_row[j] + (c1 != c2)
            current_row.append(min(insertions, deletions, substitutions))
        previous_row = current_row

    return previous_row[-1]


def check_ocr_name_variance(
    prev_name: str, curr_name: str,
    timestamp: str, cropped_path: str = ""
) -> None:
    """
    Check if two player names differ by only 1 character.
    Prints a greppable warning: [OCR_NAME_VARIANCE]
    """
    distance = levenshtein_distance(
        prev_name.upper(), curr_name.upper())
    if distance == 1:
        img_suffix = ""
        if cropped_path:
            # Show <video_id>/filename for easy copy
            parent = os.path.basename(
                os.path.dirname(cropped_path))
            fname = os.path.basename(cropped_path)
            img_suffix = f", {parent}/{fname}"
        print(
            f"[OCR_NAME_VARIANCE] at {timestamp}: "
            f"'{prev_name}' vs '{curr_name}' "
            f"(edit distance=1){img_suffix}")


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


class MatchStartFinder:
    """Main class implementing the multi-phase search strategy."""

    def __init__(self, video_path: str, output_dir: str, processor: WttVideoProcessor):
        self.video_path = video_path
        self.output_dir = output_dir
        self.processor = processor
        self.temp_dir = tempfile.mkdtemp(prefix="match_finder_")
        self.found_matches: List[MatchStart] = []

    def cleanup(self):
        """Remove temporary directory."""
        if os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir)

    def _get_temp_image_path(self, timestamp: float) -> str:
        """Generate a temporary image path for a timestamp."""
        return os.path.join(self.temp_dir, f"frame_{timestamp:.1f}.jpg")

    def _extract_and_analyze(self, timestamp: float,
                             retry: int = 0
                             ) -> Tuple[ScoreResult, str, str]:
        """Extract frame and analyze score with retry logic.

        Returns:
            Tuple of (ScoreResult, frame_image_path,
                      cropped_image_path)
        """
        actual_timestamp = timestamp + (retry * RETRY_OFFSET_SECONDS)
        image_path = self._get_temp_image_path(actual_timestamp)

        if not self.processor.extract_image(self.video_path, actual_timestamp, image_path):
            return (ScoreResult(success=False, error="Frame extraction failed"), "", "")

        result, cropped_path = self.processor.get_scoreboard(image_path, actual_timestamp)
        return result, image_path, cropped_path

    def _analyze_with_retry(
            self, timestamp: float
    ) -> Tuple[ScoreResult, str, str, float]:
        """Analyze timestamp with retry logic.

        Returns:
            Tuple of (ScoreResult, frame_path,
                      cropped_path, actual_ts)
        """
        for retry in range(MAX_RETRIES_PER_TIMESTAMP):
            actual_ts = timestamp + (
                retry * RETRY_OFFSET_SECONDS)
            result, image_path, cropped_path = (
                self._extract_and_analyze(
                    timestamp, retry))

            if result.success:
                return (result, image_path,
                        cropped_path, actual_ts)

            # Try negative offset on second retry
            if retry == 1:
                actual_ts = (
                    timestamp - RETRY_OFFSET_SECONDS)
                result, image_path, cropped_path = (
                    self._extract_and_analyze(
                        timestamp
                        - RETRY_OFFSET_SECONDS, 0))
                if result.success:
                    return (result, image_path,
                            cropped_path, actual_ts)
        return (ScoreResult(
            success=False,
            error="All retries failed"),
            "", "", timestamp)

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

    def _binary_search_match_start(self, start_ts: float, end_ts: float,
                                   end_result: ScoreResult = None,
                                   end_image: str = "") -> Optional[MatchStart]:
        """
        Binary search to find exact match start between two timestamps.
        If 0:0 is not found, falls back to early match scores (1:0, 0:1, etc.)
        and subtracts EARLY_MATCH_OFFSET seconds as approximation.

        start_ts: Last known no-score or previous match timestamp
        end_ts: First known score visible timestamp
        end_result: ScoreResult from the coarse scan at end_ts (used as fallback)
        end_image: Image path from the coarse scan at end_ts
        """
        print(
            f"  Binary search between {format_timestamp(start_ts)} "
            f"and {format_timestamp(end_ts)}")

        best_match: Optional[MatchStart] = None
        # Track earliest early match as fallback.
        # Seed with end-point coarse-scan score so the binary search always
        # has a fallback even when the score region is extremely narrow.
        earliest_early_match: Optional[Tuple[float, ScoreResult, str]] = None
        if end_result and end_result.success and end_result.is_early_match():
            earliest_early_match = (end_ts, end_result, end_image)

        while (end_ts - start_ts) > BINARY_SEARCH_PRECISION:
            mid_ts = (start_ts + end_ts) / 2
            result, image_path, _, actual_ts = (
                self._analyze_with_retry(mid_ts))

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

        result, image_path, _, actual_ts = (
            self._analyze_with_retry(search_start))

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

        if not self.processor.initialize_scoreboard_model():
            print("Failed to initialize score extractor")
            return []

        duration = self.processor.get_video_duration(self.video_path)
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
        # coarse_samples: (ts, result, image_path, cropped)
        coarse_samples: List[
            Tuple[float, ScoreResult, str, str]
        ] = []

        timestamp = 0
        while timestamp < duration:
            ts_fmt = format_timestamp(timestamp)
            print(
                f"  Sampling at {ts_fmt}...",
                end=" ")
            result, image_path, cropped_path, actual_ts = (
                self._analyze_with_retry(timestamp))

            if result.success:
                img_info = ""
                if cropped_path:
                    # Always print the full absolute path so the user can easily inspect it manually
                    import os
                    full_path = os.path.abspath(cropped_path)
                    img_info = f", {full_path}"
                print(
                    f"Score: {result.player1} "
                    f"{result.set1}:{result.set2} "
                    f"{result.player2}, "
                    f"Game: {result.game1}:"
                    f"{result.game2}"
                    f"{img_info}")

                # Check for OCR name variance
                if coarse_samples:
                    prev = coarse_samples[-1]
                    prev_result = prev[1]
                    if prev_result.success:
                        check_ocr_name_variance(
                            prev_result.player1,
                            result.player1,
                            format_timestamp(actual_ts),
                            cropped_path)
                        check_ocr_name_variance(
                            prev_result.player2,
                            result.player2,
                            format_timestamp(actual_ts),
                            cropped_path)

                # Check if this is already a match start
                if result.is_match_start():
                    candidate = MatchStart(
                        timestamp_seconds=actual_ts,
                        timestamp_formatted=format_timestamp(
                            actual_ts),
                        player1=result.player1,
                        player2=result.player2,
                        image_path=image_path
                    )
                    if not self._is_duplicate(candidate):
                        print(
                            f"    → Found match start at "
                            f"{format_timestamp(actual_ts)}")
                        saved_path = self._save_match_image(
                            image_path, actual_ts,
                            result.player1,
                            result.player2)
                        candidate.image_path = saved_path
                        self.found_matches.append(candidate)
                    else:
                        print(
                            f"    → Duplicate match start "
                            f"at "
                            f"{format_timestamp(actual_ts)}"
                            f" (same player pair), "
                            f"skipping")
            else:
                print(f"No score: {result.error}")

            coarse_samples.append(
                (actual_ts, result, image_path,
                 cropped_path))
            timestamp += COARSE_INTERVAL_SECONDS

        phase1_duration = time.time() - phase1_start
        print(f"Phase 1 completed in {phase1_duration:.1f} seconds")

        # Phase 2: Find transitions and binary search
        phase2_start = time.time()
        print(f"\n=== Phase 2: Binary Search for Match Starts ===")
        print(f"Started at: {datetime.now().strftime('%H:%M:%S')}")

        for i in range(1, len(coarse_samples)):
            prev_ts, prev_result, _, _ = (
                coarse_samples[i - 1])
            curr_ts, curr_result, curr_image, _ = (
                coarse_samples[i])

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
                    no_score_start, curr_ts,
                    end_result=curr_result, end_image=curr_image)
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

                match_start = self._binary_search_match_start(
                    prev_ts, curr_ts,
                    end_result=curr_result, end_image=curr_image)
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

                match_start = self._binary_search_match_start(
                    prev_ts, curr_ts,
                    end_result=curr_result, end_image=curr_image)
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

        # Collect all unique player pairs seen during coarse scan
        seen_pairs: List[Tuple[str, str, str]] = []  # (p1, p2, timestamp)
        for ts, result, _, _ in coarse_samples:
            if not result.success:
                continue
            p1, p2 = result.player1, result.player2
            # Check if this pair is already seen (using is_similar)
            already_seen = False
            for sp1, sp2, _ in seen_pairs:
                if ((is_similar(p1, sp1) and is_similar(p2, sp2)) or
                        (is_similar(p1, sp2) and is_similar(p2, sp1))):
                    already_seen = True
                    break
            if not already_seen:
                seen_pairs.append((p1, p2, format_timestamp(ts)))

        # Check for skipped matches: pairs seen but not in found_matches
        for sp1, sp2, first_seen_ts in seen_pairs:
            found = False
            for m in self.found_matches:
                if ((is_similar(sp1, m.player1) and is_similar(sp2, m.player2)) or
                        (is_similar(sp1, m.player2) and is_similar(sp2, m.player1))):
                    found = True
                    break
            if not found:
                print(f"[MATCH_SKIPPED_WARNING] Players '{sp1}' vs "
                      f"'{sp2}' seen at {first_seen_ts} but no match "
                      f"start found in output")

        total_duration = time.time() - total_start_time
        print("\n=== Summary ===")
        print(f"Phase 1 (Coarse Scan): {phase1_duration:.1f} seconds")
        print(f"Phase 2 (Binary Search): {phase2_duration:.1f} seconds")
        print(f"Total time: {total_duration:.1f} seconds")
        print(f"Match starts found: {len(self.found_matches)}")

        return self.found_matches

    def _is_duplicate(self, match: MatchStart) -> bool:
        """Check if match start already found (within MIN_BREAK_DURATION or same player pair)."""

        for existing in self.found_matches:
            # Duplicate if same player pair (regardless of timestamp)
            # Use is_similar to allow 1 character drop leniency in matching pairs
            players_match_straight = (is_similar(match.player1, existing.player1) and
                                      is_similar(match.player2, existing.player2))
            players_match_swapped = (is_similar(match.player1, existing.player2) and
                                     is_similar(match.player2, existing.player1))

            if players_match_straight or players_match_swapped:
                return True

            # Duplicate if too close in time
            if abs(existing.timestamp_seconds - match.timestamp_seconds) < MIN_BREAK_DURATION:
                return True
        return False

    def _players_changed(self, prev: ScoreResult, curr: ScoreResult) -> bool:
        """Check if players changed between two samples."""
        players_match_straight = (is_similar(prev.player1, curr.player1) and
                                  is_similar(prev.player2, curr.player2))
        players_match_swapped = (is_similar(prev.player1, curr.player2) and
                                 is_similar(prev.player2, curr.player1))

        # Players changed if they don't match straight or swapped
        return not (players_match_straight or players_match_swapped)

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
        video_id = youtube_url.rstrip('/').split('/')[-1].split('?')[0]
    return video_id


def main():
    import json
    parser = argparse.ArgumentParser(
        description='Find match start timestamps in table tennis videos')

    # Standalone action: list recent streams
    parser.add_argument('--print_matches', type=int, metavar='NUM',
                        help='List NUM recent WTT streams (completed live '
                             'streams only) and exit')

    # Batch processing: process all videos newer than specified video_id
    parser.add_argument('--process_all_matches_after', type=str,
                        metavar='VIDEO_ID',
                        help='Process all completed WTT streams newer than '
                             'VIDEO_ID (fetches last 100 streams)')

    # Video source (mutually exclusive)
    video_group = parser.add_mutually_exclusive_group(required=False)
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
    parser.add_argument('--cuda_device_id', type=int, default=None,
                        help='The ID of the CUDA device to use for PyTorch (if multiple are available)')
    parser.add_argument('--cuda_device_name', type=str, default=None,
                        help='The exact string name of the GPU to map via PyTorch (prevents index mismatch between nvidia-smi and torch)')
    parser.add_argument('--backend', type=str, default=None,
                        choices=ALL_BACKENDS,
                        help='Inference backend: pytorch-cpu or openvino')
    parser.add_argument('--test_golden_dataset', type=str, default=None,
                        help='Path to a golden JSON dataset for pure hermetic testing (skips all downloading and ML)')
    parser.add_argument('--keep_cropped', action='store_true',
                        help='Save cropped score images to cropped_frames/')
    parser.add_argument('--output_json_file', type=str, default=None,
                        help='Path to output JSON file with match data')
    parser.add_argument(
        '--crop_output_dir', type=str, default=None,
        help='Directory to save cropped score images '
             '(e.g., /log/<video_id>/)')
    parser.add_argument('--only_extract_video_metadata', action='store_true',
                        help='Only extract video metadata (id, title, upload_date) '
                             'without running match detection')
    parser.add_argument('--cookies_file', type=str, default=None,
                        help='Path to a Netscape HTTP Cookie File for yt-dlp')
    args = parser.parse_args()

    # Determine backend
    backend = args.backend or get_default_backend()
    device = 'cpu'
    if not args.only_extract_video_metadata:
        device = 'cpu' if args.test_golden_dataset else (get_device(args) if backend == BACKEND_PYTORCH else 'cpu')

    # Print the resolved device immediately
    dev_name_print = ""
    if str(device).startswith("cuda"):
        try:
            idx = int(str(device).split(":")[1]) if ":" in str(device) else 0
            dev_name_print = f" ({torch.cuda.get_device_name(idx)})"
        except Exception:
            pass
    print(f"Resolved execution device: {device}{dev_name_print}")

    # Initialize processor
    crop_dir = args.crop_output_dir if args.crop_output_dir else (os.path.join(args.output, "cropped_frames") if args.keep_cropped else None)
    if crop_dir:
        os.makedirs(crop_dir, exist_ok=True)
    if args.test_golden_dataset:
        print(f"Running in HERMETIC MODE using golden dataset: {args.test_golden_dataset}")
        processor = TestWttVideoProcessor(args.test_golden_dataset)
    else:
        processor = ProdWttVideoProcessor(backend=backend, device=device, cropped_dir=crop_dir)

    # Handle --print_matches (standalone action)
    if args.print_matches:
        processor.list_recent_streams(args.print_matches)
        sys.exit(0)

    # Handle --process_all_matches_after (batch processing)
    if args.process_all_matches_after:
        print(
            f"Fetching videos newer than {args.process_all_matches_after}...")
        videos = processor.get_videos_after(args.process_all_matches_after)

        if not videos:
            print("No videos found newer than the specified video ID.")
            print("(Video ID may not exist or there are no newer "
                  "completed streams)")
            if args.output_json_file:
                with open(args.output_json_file, 'w') as f:
                    json.dump([], f)
                print(f"Empty JSON written to: {args.output_json_file}")
            sys.exit(0)

        print(f"\nFound {len(videos)} videos to process")

        # If --only_extract_video_metadata, write JSON with metadata and exit
        if args.only_extract_video_metadata:
            if args.output_json_file:
                # Build metadata-only JSON (empty matches array for each video)
                metadata_results = [
                    {
                        "video_id": v.get('id'),
                        "video_title": v.get('title'),
                        "upload_date": v.get('upload_date'),
                        "matches": []
                    }
                    for v in videos
                ]
                with open(args.output_json_file, 'w') as f:
                    json.dump(metadata_results, f, indent=2)
                print(f"\nJSON output written to: {args.output_json_file}")
            print(f"\n(Dry run - {len(videos)} videos would be processed)")
            sys.exit(0)

        # Create output directory
        os.makedirs(args.output, exist_ok=True)

        # Collect all results for single JSON output
        all_results = []

        # Process each video
        print(f"\n{'=' * 60}")
        print(f"Starting batch processing of {len(videos)} videos...")
        print('=' * 60)

        # Reverse to process oldest first
        for i, video in enumerate(reversed(videos), 1):
            vid = video.get('id')
            title = video.get('title', 'Unknown')
            upload_date = video.get('upload_date')

            print(f"\n[{i}/{len(videos)}] Processing: {title}")
            print(f"  Video ID: {vid}")

            youtube_url = f"https://www.youtube.com/watch?v={vid}"

            # Download video
            video_path = download_youtube_video(youtube_url, args.output)
            if not video_path:
                print("  ERROR: Failed to download video, skipping...")
                continue

            # Determine backend
            backend = args.backend or get_default_backend()

            # Determine crop output dir for this video
            crop_dir = args.crop_output_dir if args.crop_output_dir else (os.path.join(args.output, "cropped_frames") if args.keep_cropped else None)
            if crop_dir and args.crop_output_dir:
                crop_dir = os.path.join(args.crop_output_dir, vid)
            if crop_dir:
                os.makedirs(crop_dir, exist_ok=True)

            # Find matches
            device = 'cpu' if args.test_golden_dataset else (get_device(args) if backend == BACKEND_PYTORCH else 'cpu')

            # Print the resolved device immediately
            dev_name_print = ""
            if str(device).startswith("cuda"):
                try:
                    idx = int(str(device).split(":")[1]) if ":" in str(device) else 0
                    dev_name_print = f" ({torch.cuda.get_device_name(idx)})"
                except Exception:
                    pass
            print(f"Resolved execution device: {device}{dev_name_print}")
            if hasattr(processor, 'cropped_dir'):
                processor.cropped_dir = crop_dir
            finder = MatchStartFinder(
                video_path=video_path,
                output_dir=args.output,
                processor=processor
            )

            try:
                matches = finder.find_match_starts()

                video_result = {
                    "video_id": vid,
                    "video_title": title,
                    "upload_date": upload_date,
                    "matches": [
                        {
                            "timestamp": int(
                                m.timestamp_seconds),
                            "player1": m.player1,
                            "player2": m.player2
                        }
                        for m in matches
                    ],
                }
                if not matches:
                    video_result["error"] = (
                        "No match starts found")
                all_results.append(video_result)

                if matches:
                    print(
                        f"  Found {len(matches)} "
                        f"match starts")
                else:
                    print("  No match starts found")
            finally:
                finder.cleanup()

        # Write single JSON output with all videos
        json_path = args.output_json_file or os.path.join(
            args.output, "all_matches.json")
        with open(json_path, 'w') as f:
            json.dump(all_results, f, indent=2)
        print(f"\nJSON output written to: {json_path}")

        print(f"\n{'=' * 60}")
        print(f"Batch processing complete: {len(videos)} videos processed")
        print(f"Total videos with results: {len(all_results)}")
        print('=' * 60)
        sys.exit(0)

    # Validate that a video source is provided if not using batch modes
    if not args.local_video and not args.youtube_video:
        parser.error("Either --local_video, --youtube_video, "
                     "--print_matches, or --process_all_matches_after "
                     "is required")

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
    upload_date = None  # Unix UTC timestamp string

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
        try:
            video_title, upload_date = processor.fetch_video_info(args.youtube_video, args.cookies_file)
            
            if not video_title or not upload_date:
                error_msg = "Failed to fetch video title or upload date (yt-dlp may be blocked or video unavailable)"
                print(f"Error: {error_msg}")
                if args.output_json_file:
                    json_data = {
                        "video_id": video_id,
                        "video_title": video_title,
                        "upload_date": upload_date,
                        "matches": [],
                        "error": error_msg,
                    }
                    with open(args.output_json_file, 'w') as f:
                        json.dump(json_data, f, indent=2)
                    print(f"Error JSON written to: {args.output_json_file}")
                sys.exit(1)
                
            print(f"Video Title: {video_title}")
            print(f"Upload Date: {upload_date}")
        except FileNotFoundError as e:
            print(str(e))
            if args.output_json_file:
                json_data = {
                    "video_id": video_id,
                    "video_title": None,
                    "upload_date": None,
                    "matches": [],
                    "error": str(e),
                }
                with open(args.output_json_file, 'w') as f:
                    json.dump(json_data, f, indent=2)
                print(f"Error JSON written to: {args.output_json_file}")
            sys.exit(1)

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
        try:
            video_path = processor.download_video(args.youtube_video, args.output, args.cookies_file)
        except FileNotFoundError as e:
            print(str(e))
            if args.output_json_file:
                json_data = {
                    "video_id": video_id,
                    "video_title": video_title,
                    "upload_date": upload_date,
                    "matches": [],
                    "error": str(e),
                }
                with open(args.output_json_file, 'w') as f:
                    json.dump(json_data, f, indent=2)
                print(f"Error JSON written to: {args.output_json_file}")
            sys.exit(1)

        if not video_path:
            error_msg = "Failed to download YouTube video"
            print(f"{error_msg}.")
            # Write error to output JSON so the Go importer can record it
            if args.output_json_file:
                json_data = {
                    "video_id": video_id,
                    "video_title": video_title,
                    "upload_date": upload_date,
                    "matches": [],
                    "error": error_msg,
                }
                with open(args.output_json_file, 'w') as f:
                    json.dump(json_data, f, indent=2)
                print(f"Error JSON written to: {args.output_json_file}")
            sys.exit(1)

    print(f"\n{'=' * 60}")
    print("Match Start Finder")
    print('=' * 60)
    print(f"Video: {video_path}")
    print(f"Output directory: {args.output}")
    print(f"Backend: {backend}")
    print('=' * 60)

    # Determine crop output dir for single video
    crop_dir = args.crop_output_dir if args.crop_output_dir else (os.path.join(args.output, "cropped_frames") if args.keep_cropped else None)
    if crop_dir and video_id and args.crop_output_dir: # only append video_id if they passed crop_output_dir directly, otherwise stick to output/cropped_frames/
        crop_dir = os.path.join(args.crop_output_dir, video_id)
        
    if crop_dir:
        os.makedirs(crop_dir, exist_ok=True)

    if hasattr(processor, 'cropped_dir'):
        processor.cropped_dir = crop_dir
    finder = MatchStartFinder(
        video_path=video_path, output_dir=args.output, processor=processor
    )

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
        else:
            print("\nNo match starts found.")

        # Always write JSON output if requested
        if args.output_json_file:
            json_data = {
                "video_id": video_id,
                "video_title": video_title,
                "upload_date": upload_date,
                "matches": [
                    {
                        "timestamp": int(
                            m.timestamp_seconds),
                        "player1": m.player1,
                        "player2": m.player2
                    }
                    for m in matches
                ],
            }
            if not matches:
                json_data["error"] = (
                    "No match starts found")
            with open(
                    args.output_json_file, 'w') as f:
                json.dump(json_data, f, indent=2)
            print(
                f"\nJSON output written to: "
                f"{args.output_json_file}")
    except Exception as e:
        # Ensure output JSON is always written, even on unexpected errors
        error_msg = f"Processing failed: {e}"
        print(f"\nERROR: {error_msg}")
        traceback.print_exc()
        if args.output_json_file:
            json_data = {
                "video_id": video_id,
                "video_title": video_title,
                "upload_date": upload_date,
                "matches": [],
                "error": error_msg,
            }
            with open(args.output_json_file, 'w') as f:
                json.dump(json_data, f, indent=2)
            print(f"Error JSON written to: {args.output_json_file}")
        sys.exit(1)
    finally:
        finder.cleanup()


if __name__ == "__main__":
    main()
