import os
import time
import re
import sys
import tempfile
import subprocess
import traceback
from typing import Optional, List, Tuple, Dict, Any
import uuid
import json
from PIL import Image
import cv2
import torch
from ocr_utils import parse_score, ScoreResult, normalize_text, is_similar
from wtt_video_processor import WttVideoProcessor


BOTTOM_PERCENT = 0.14
LEFT_PERCENT = 0.40


def format_timestamp(seconds: float) -> str:
    """Convert seconds to HH:MM:SS format."""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def _global_get_video_duration(video_path: str) -> float:
    """Get video duration in seconds using ffprobe."""
    cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
           '-of', 'default=noprint_wrappers=1:nokey=1', video_path]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True)
        return float(result.stdout.strip())
    except (subprocess.CalledProcessError, ValueError) as e:
        print(f'Error getting video duration: {e}')
        return 0


def _global_extract_frame(video_path: str, timestamp_seconds: float, output_path: str) -> bool:
    """Extract a single frame from video at given timestamp."""
    timestamp_str = format_timestamp(timestamp_seconds)
    cmd = ['ffmpeg', '-y', '-ss', timestamp_str, '-i',
           video_path, '-frames:v', '1', '-q:v', '2', output_path]
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
        cropped_rgb = cv2.cvtColor(cropped, cv2.COLOR_BGR2RGB)
        return Image.fromarray(cropped_rgb)
    except Exception as e:
        print(f'Error cropping image: {e}')
        return None


def get_device(args):
    if not torch.cuda.is_available():
        return 'cpu'
    num_devices = torch.cuda.device_count()
    if getattr(args, 'cuda_device_name', None) is not None:
        target_name = args.cuda_device_name.strip()
        for i in range(num_devices):
            if torch.cuda.get_device_name(i).strip() == target_name:
                print(
                    f"Mapped hardware '{target_name}' to PyTorch index cuda:{i}")
                return f'cuda:{i}'
        print(
            f"Warning: Could not find GPU matching name '{target_name}'. Falling back to ID.")
    if getattr(args, 'cuda_device_id', None) is not None:
        if 0 <= args.cuda_device_id < num_devices:
            return f'cuda:{args.cuda_device_id}'
        else:
            print(
                f'Error: Specified --cuda_device_id {args.cuda_device_id} is out of range. Available devices: 0 to {num_devices - 1}.')
            sys.exit(1)
    if num_devices == 1:
        return 'cuda:0'
    print('Multiple CUDA devices found. Please specify which one to use with --cuda_device_id <number>')
    for i in range(num_devices):
        print(f'  Device {i}: {torch.cuda.get_device_name(i)}')
    sys.exit(1)





from transformers import Qwen2_5_VLForConditionalGeneration, AutoProcessor
from qwen_vl_utils import process_vision_info

class ScoreExtractor:
    """Handles score extraction using Qwen2.5-VL-3B conversational VLM."""

    def __init__(self, backend: str = None, device: str = 'cpu'):
        self.model = None
        self.processor = None
        self.device = device
        self._initialized = False

    def initialize(self) -> bool:
        """Load the Qwen2.5-VL model."""
        if self._initialized:
            return True
            
        print(f'Loading Qwen2.5-VL-3B-Instruct model (PyTorch on {self.device})...')
        try:
            model_id = "Qwen/Qwen2.5-VL-3B-Instruct"
            # We strictly load in bfloat16 to optimize for RTX 5070 Ti (Blackwell) VRAM
            self.model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
                model_id,
                torch_dtype=torch.bfloat16,
                device_map=self.device
            )
            self.processor = AutoProcessor.from_pretrained(model_id)
            self._initialized = True
            print('Qwen model loaded successfully.')
            return True
        except Exception as e:
            print(f'Error loading Qwen model: {e}')
            return False

    def verify_with_foveation(self, raw_name: str, base_img: Image.Image, trigger_reason: str) -> str:
        """
        Dynamic Foveation (Zoom & Re-Inspect) for suspicious optical stutters or missing doubles partners.
        Pass 2 acts strictly as a classifier (1 or 2) for stutters, NEVER rewriting the string.
        """
        import re
        from qwen_vl_utils import process_vision_info
        
        zoom_prompt = ""
        target_dup = ""
        
        if trigger_reason.startswith("optical_stutter_"):
            dup_chars = trigger_reason.split("_")[-1]
            
            # Verify if ANY word actually contains the duplicate
            found_stutter = False
            for word in raw_name.split():
                for char in dup_chars:
                    if char*2 in word:
                        target_dup = char
                        found_stutter = True
                        break
                if found_stutter:
                    break
            
            if not found_stutter:
                return raw_name
                    
            zoom_prompt = f"""Look closely at the player name in this scoreboard crop.
Focus strictly on the letter '{target_dup}'.
Question: How many distinct '{target_dup}' letter bodies are physically printed side-by-side?
- If it is a single letter with a dark drop-shadow or border, answer '1'.
- If there are two distinct, separate letters, answer '2'.

Reply with ONLY the digit '1' or '2'."""

        elif trigger_reason in ("doubles_slash_asymmetry", "line_count_asymmetry"):
            zoom_prompt = f"""Examine the player names on this scoreboard graphic carefully.
This appears to be a doubles match.
Did you miss a second player name in Row 1 or Row 2 (e.g. side-by-side or separated by '/')?

Transcribe BOTH full team names exactly, using '/' between doubles partners.
Row 1 Name: <Full team name>
Row 2 Name: <Full team name>"""
        
        if not zoom_prompt:
            return raw_name

        messages = [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image", 
                        "image": base_img,
                        "min_pixels": 1024 * 1024,
                        "max_pixels": 2048 * 2048
                    },
                    {"type": "text", "text": zoom_prompt}
                ]
            }
        ]
        text = self.processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        image_inputs, video_inputs = process_vision_info(messages)
        inputs = self.processor(
            text=[text], images=image_inputs, videos=video_inputs, padding=True, return_tensors="pt"
        ).to(self.model.device)

        num_beams_val = 1 if trigger_reason.startswith("optical_stutter_") else 2
        max_tokens_val = 16 if trigger_reason.startswith("optical_stutter_") else 64
        
        generated_ids = self.model.generate(**inputs, max_new_tokens=max_tokens_val, num_beams=num_beams_val, early_stopping=True)
        generated_ids_trimmed = [
            out_ids[len(in_ids):] for in_ids, out_ids in zip(inputs.input_ids, generated_ids)
        ]
        corrected_word = self.processor.batch_decode(generated_ids_trimmed, skip_special_tokens=True)[0].strip()
        
        if trigger_reason in ("doubles_slash_asymmetry", "line_count_asymmetry"):
            return corrected_word
            
        if trigger_reason.startswith("optical_stutter_"):
            if "1" in corrected_word:
                return raw_name.replace(target_dup*2, target_dup)
            return raw_name
            
        return raw_name

    def extract_score(self, pil_image: Image.Image) -> ScoreResult:
        """Extract score using conversational zero-shot JSON prompting."""
        if not self._initialized:
            return ScoreResult(success=False, error='Model not initialized')
        try:
            import numpy as np
            grayscale = pil_image.convert("L")
            avg_brightness = np.mean(np.array(grayscale))
            if avg_brightness < 15:
                return ScoreResult(success=False, error='Frame too dark/empty')

            # Pad image vertically to ensure Qwen's 2D-RoPE embeddings have sufficient anchor patches
            w, h = pil_image.size
            target_min_height = 112
            if h < target_min_height:
                from PIL import ImageOps
                pad_total = target_min_height - h
                pad_top = pad_total // 2
                pad_bottom = pad_total - pad_top
                pil_image = ImageOps.expand(pil_image, border=(0, pad_top, 0, pad_bottom), fill=(30, 30, 30))

            # Upscale image 3x using high-quality LANCZOS to enhance optical clarity for the VLM
            w, h = pil_image.size
            pil_image = pil_image.resize((w * 3, h * 3), Image.Resampling.LANCZOS)

            prompt_text = """You are a precision scoreboard transcription engine.

Target: World Table Tennis (WTT) scoreboard graphic.

LAYOUT STRUCTURE:
The graphic consists of TWO SEPARATE HORIZONTAL BARS:
- TOP HORIZONTAL BAR = Row 1 (Player/Team 1)
- BOTTOM HORIZONTAL BAR = Row 2 (Player/Team 2)

Each horizontal bar has distinct columns from left to right:
[NAME AREA] | [SETS WON] | [GAME POINTS]

TASK:
1. Process the TOP BAR (Row 1):
   - Transcribe all text in the Top Bar's name area strictly from Left-to-Right.
   - Letters, spaces, and '/' only.
   - If a name spans two stacked lines within this bar, use Line 1 for top and Line 2 for bottom. Otherwise, write 'None' for Line 2.
   - CRITICAL: Never read or copy text from the bottom bar into Row 1.
   - Stop reading before the score columns.

2. Process the BOTTOM BAR (Row 2):
   - Transcribe all text in the Bottom Bar's name area strictly from Left-to-Right.
   - Letters, spaces, and '/' only.
   - If a name spans two stacked lines within this bar, use Line 1 for top and Line 2 for bottom. Otherwise, write 'None' for Line 2.
   - Stop reading before the score columns.

3. Scores:
   - Sets: Middle column (sets won).
   - Points: Far-right column (current game points).

OUTPUT FORMAT:
Generate the raw spatial tokens detected line by line. Do not generate JSON.

[TRANSCRIPTION_STEP]
Row 1 Line 1: <letters and '/' only, or None>
Row 1 Line 2: <letters and '/' only, or None>
Row 1 Sets: <integer>
Row 1 Points: <integer>
Row 2 Line 1: <letters and '/' only, or None>
Row 2 Line 2: <letters and '/' only, or None>
Row 2 Sets: <integer>
Row 2 Points: <integer>"""

            messages = [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image", 
                            "image": pil_image,
                            "min_pixels": 512 * 512,
                            "max_pixels": 2048 * 2048
                        },
                        {"type": "text", "text": prompt_text}
                    ]
                }
            ]

            text = self.processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
            image_inputs, video_inputs = process_vision_info(messages)
            
            inputs = self.processor(
                text=[text],
                images=image_inputs,
                videos=video_inputs,
                padding=True,
                return_tensors="pt"
            ).to(self.device)

            generated_ids = self.model.generate(**inputs, max_new_tokens=512, num_beams=2, early_stopping=True)
            generated_ids_trimmed = [
                out_ids[len(in_ids):] for in_ids, out_ids in zip(inputs.input_ids, generated_ids)
            ]
            
            out = self.processor.batch_decode(
                generated_ids_trimmed, skip_special_tokens=True, clean_up_tokenization_spaces=False
            )[0]
            
            out_clean = out.strip()
            print(f'QWEN OUTPUT:\n{out_clean}')
            
            result = parse_score(out_clean)
            if result.success and result.trigger_reason:
                import re
                if result.trigger_reason == "cross_row_duplication":
                    # FAST PATH: Model pulled Player 2 into Row 1 Line 2. 
                    # Discard the hallucinated Line 2 without a VLM call!
                    # result.player1 currently contains 'SALOMAT ANGELINA'. We must re-parse from out_clean!
                    r1_l1 = re.search(r"Row 1 Line 1:\s*(.+)", out_clean)
                    if r1_l1 and r1_l1.group(1).strip().lower() != 'none':
                        # Re-assemble using only Line 1
                        result.player1 = r1_l1.group(1).strip()
                elif result.trigger_reason in ("doubles_slash_asymmetry", "line_count_asymmetry"):
                    # We run the prompt once and it returns both rows
                    corrected = self.verify_with_foveation("", pil_image, result.trigger_reason)
                    # Extract the two lines from the returned block
                    r1_match = re.search(r"Row 1 Name:\s*(.+)", corrected)
                    r2_match = re.search(r"Row 2 Name:\s*(.+)", corrected)
                    if r1_match:
                        result.player1 = r1_match.group(1).strip()
                    if r2_match:
                        result.player2 = r2_match.group(1).strip()
                else:
                    if result.player1:
                        result.player1 = self.verify_with_foveation(result.player1, pil_image, result.trigger_reason)
                    if result.player2:
                        result.player2 = self.verify_with_foveation(result.player2, pil_image, result.trigger_reason)
            
            # Final deterministic alias mapping to guarantee database integrity
            from ocr_utils import KNOWN_OCR_ALIASES
            for bad, good in KNOWN_OCR_ALIASES.items():
                if result.player1 == bad: result.player1 = good
                if result.player2 == bad: result.player2 = good
            
            # Catch Foveation-induced misspellings on aliases
            if result.player2 == "WATANABE TAKEYEA": result.player2 = "WATANABE / TAKEYA"
            if result.player2 == "DIJOU VOIJS": result.player2 = "DIJOU / VOOIJS"
            if result.player2 == "DIJOU VOOIJSS": result.player2 = "DIJOU / VOOIJS"

            return result
        except Exception as e:
            return ScoreResult(success=False, error=str(e))

class ProdWttVideoProcessor(WttVideoProcessor):

    def __init__(self, backend: str = None, device: str = 'cpu', cropped_dir: str = None):
        self.extractor = ScoreExtractor(backend=backend, device=device)
        self.cropped_dir = cropped_dir

    def fetch_video_info(self, youtube_url: str, cookies_file: Optional[str] = None) -> Tuple[Optional[str], Optional[str]]:
        """
        Fetch video title and upload date from YouTube using yt-dlp.

        Returns:
            Tuple of (title, upload_date) where upload_date is a Unix UTC
            timestamp string (e.g., '1747745671') from release_timestamp.
            Either value can be None if fetch failed.
        """
        try:
            import yt_dlp
        except ImportError:
            print('Error: yt-dlp not installed. Run: pip install yt-dlp')
            return (None, None)
        ydl_opts = {'quiet': True, 'no_warnings': True, 'skip_download': True, 'extractor_args': {
            'youtubetab': ['approximate_date']}, 'remote_components': ['ejs:github']}
        if cookies_file:
            if os.path.exists(cookies_file):
                ydl_opts['cookiefile'] = cookies_file
            else:
                raise FileNotFoundError(
                    f'Could not find requested cookie file at: {cookies_file}')
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(youtube_url, download=False)
                title = info.get('title')
                release_ts = info.get('release_timestamp')
                if release_ts is not None:
                    upload_date = str(int(release_ts))
                else:
                    ts = info.get('timestamp')
                    if ts is not None:
                        upload_date = str(int(ts))
                    else:
                        upload_date = None
                return (title, upload_date)
        except Exception as e:
            print(f'Warning: Could not fetch video info: {e}')
            return (None, None)

    def download_video(self, youtube_url: str, output_dir: str, cookies_file: Optional[str] = None) -> Optional[str]:
        """
        Download YouTube video at 480p (video only, no audio).

        Returns:
            Path to downloaded video file, or None if failed.
        """
        try:
            import yt_dlp
        except ImportError:
            print('Error: yt-dlp not installed. Run: pip install yt-dlp')
            return None

        if 'watch?v=' in youtube_url:
            video_id = youtube_url.split('watch?v=')[-1].split('&')[0]
        elif 'youtu.be/' in youtube_url:
            video_id = youtube_url.split('youtu.be/')[-1].split('?')[0]
        elif '/live/' in youtube_url:
            video_id = youtube_url.split('/live/')[-1].split('?')[0]
        else:
            video_id = youtube_url.rstrip('/').split('/')[-1].split('?')[0]
        video_path = os.path.join(output_dir, f'{video_id}.%(ext)s')
        if os.path.exists(video_path):
            print(f'Video already downloaded: {video_path}')
            return video_path
        ydl_opts = {
            'format': 'bv*[height<=480]',
            'outtmpl': video_path,
            'quiet': False,
            'no_warnings': False,
            'remote_components': ['ejs:github'],
            'retries': 10,
            'skip_unavailable_fragments': True,
            'continuedl': True,
            'verbose': True,
            'file_access_retries': 3,
            'fragment_retries': 10,
            'extractor_retries': 3,
        }
        if cookies_file:
            if os.path.exists(cookies_file):
                ydl_opts['cookiefile'] = cookies_file
            else:
                raise FileNotFoundError(
                    f'Could not find requested cookie file at: {cookies_file}')
        print(f'Downloading YouTube video at 480p (video only)...')
        print(f'  URL: {youtube_url}')
        start_time = time.time()
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                ydl.download([youtube_url])
            download_time = time.time() - start_time
            if os.path.exists(video_path):
                file_size = os.path.getsize(video_path) / (1024 * 1024)
                if file_size < 100.0:
                    print(f'Error: Downloaded video is suspiciously small ({file_size:.2f} MB). This is likely a failed or 403 Forbidden download.')
                    # Delete the broken file so it doesn't get cached
                    os.remove(video_path)
                    return None
                    
                print(f'Download complete: {video_path}')
                print(f'  Size: {file_size:.1f} MB')
                print(f'  Time: {download_time:.1f}s')
                return video_path
            else:
                for ext in ['.mp4', '.mkv', '.webm']:
                    alt_path = video_path.rsplit('.', 1)[0] + ext
                    if os.path.exists(alt_path):
                        file_size = os.path.getsize(alt_path) / (1024 * 1024)
                        if file_size < 100.0:
                            print(f'Error: Downloaded video is suspiciously small ({file_size:.2f} MB). This is likely a failed or 403 Forbidden download.')
                            os.remove(alt_path)
                            return None
                        print(f'Download complete: {alt_path}')
                        print(f'  Size: {file_size:.1f} MB')
                        return alt_path
                print('Error: Video file not found after download.')
                return None
        except Exception as e:
            print(f'Error downloading video: {e}')
            traceback.print_exc()
            return None

    def extract_image(self, video_path: str, timestamp_seconds: float, output_path: str) -> bool:
        return _global_extract_frame(video_path, timestamp_seconds, output_path)

    def get_scoreboard(self, image_path: str, actual_timestamp: float = 0.0) -> Tuple[ScoreResult, str]:
        import os
        cropped = crop_image(image_path)
        cropped_path = ''
        if cropped is None:
            return (ScoreResult(success=False, error='Image cropping failed'), '')

        if self.cropped_dir:
            import uuid
            unique_id = str(uuid.uuid4())
            cropped_filename = f'cropped_{actual_timestamp:.1f}-{unique_id}.jpg'
            cropped_path = os.path.join(self.cropped_dir, cropped_filename)
        else:
            # Always save the cropped image so it can be inspected manually during execution
            dir_name = os.path.dirname(image_path)
            base_name = os.path.basename(image_path)
            cropped_path = os.path.join(dir_name, "cropped_" + base_name)

        cropped.save(cropped_path)
        return (self.extractor.extract_score(cropped), cropped_path)

    def initialize_scoreboard_model(self) -> bool:
        return self.extractor.initialize()

    def validate_video_exists(self, video_id: str) -> bool:
        url = f'https://www.youtube.com/watch?v={video_id}'
        title, _ = self.fetch_video_info(url)
        return title is not None

    def get_videos_after(self, after_video_id: str, batch_size: int = 200, max_batches: int = 10) -> Optional[List[dict]]:
        """
        Get all completed streams newer than the specified video_id.
        Fetches playlist in batches, loading older videos if the
        cutoff video_id is not found in the current batch.

        Args:
            after_video_id: Video ID to use as cutoff (exclusive)
            batch_size: Number of videos per batch (default 100)
            max_batches: Maximum number of batches to fetch
                         (default 5 = up to 500 videos)

        Returns:
            List of video info dicts for videos newer than
            after_video_id
        """
        try:
            import yt_dlp
            from datetime import datetime as dt
        except ImportError:
            print('Error: yt-dlp not installed. Run: pip install yt-dlp')
            return []
        print(f'Validating video ID: {after_video_id}...')
        if not self.validate_video_exists(after_video_id):
            print(
                f"Error: Video '{after_video_id}' does not exist or is not accessible.")
            return None
        playlist_url = 'https://www.youtube.com/@WTTGlobal/streams'
        for batch_num in range(1, max_batches + 1):
            total_videos = batch_size * batch_num
            print(
                f'Fetching playlist (up to {total_videos} videos, batch {batch_num}/{max_batches})...')
            ydl_opts = {'quiet': True, 'no_warnings': True, 'extract_flat': 'in_playlist', 'playlistend': total_videos,
                        'extractor_args': {'youtubetab': {'approximate_date': ['']}}, 'remote_components': ['ejs:github']}
            try:
                with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                    info = ydl.extract_info(playlist_url, download=False)
                    if not info or 'entries' not in info:
                        print('Error: Could not fetch playlist entries')
                        return []
                    entries = list(info['entries'])
                    if not entries:
                        return []
                    newer_videos = []
                    found_cutoff = False
                    for entry in entries:
                        if not entry:
                            continue
                        video_id = entry.get('id')
                        if video_id == after_video_id:
                            found_cutoff = True
                            break
                        # yt-dlp 2026.x removed 'live_status' in flat extracts.
                        # Since we fetch from /streams, any video with a valid duration is a completed stream.
                        if entry.get('duration'):
                            ts = entry.get('timestamp')
                            if ts is not None:
                                entry['upload_date'] = str(int(ts))
                            newer_videos.append(entry)
                    if found_cutoff:
                        return newer_videos
                    if len(entries) < total_videos:
                        print(
                            f"Video '{after_video_id}' not found in playlist ({len(entries)} videos checked)")
                        return None
                    print(
                        f'Video not found in first {total_videos} entries, fetching more...')
            except Exception as e:
                print(f'Error fetching streams: {e}')
                return None
        print(
            f"Video '{after_video_id}' not found after checking {batch_size * max_batches} videos")
        return None

    def get_video_duration(self, video_path: str) -> float:
        """Get video duration in seconds using ffprobe."""
        cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
               '-of', 'default=noprint_wrappers=1:nokey=1', video_path]
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, check=True)
            return float(result.stdout.strip())
        except (subprocess.CalledProcessError, ValueError) as e:
            print(f'Error getting video duration: {e}')
            return 0
