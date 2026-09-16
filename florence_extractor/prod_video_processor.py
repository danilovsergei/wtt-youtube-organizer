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
from peft import PeftModel
from qwen_vl_utils import process_vision_info

class ScoreExtractor:
    """Handles score extraction using Qwen2.5-VL-3B conversational VLM."""

    def __init__(self, backend: str = None, device: str = 'cpu'):
        self.model = None
        self.processor = None
        self.device = device
        self._initialized = False

    def initialize(self) -> bool:
        """Load the fine-tuned Qwen2.5-VL model with LoRA adapters."""
        if self._initialized:
            return True
            
        print(f'Loading Fine-Tuned Qwen2.5-VL-3B-Instruct LoRA model (PyTorch on {self.device})...')
        try:
            model_id = "Qwen/Qwen2.5-VL-3B-Instruct"
            lora_dir = "/home/geonix/Build/wtt-youtube-organizer/florence_extractor/output/qwen2.5-vl-3b-wtt-lora/v4-20260914-115927/checkpoint-1119"
            
            # We strictly load in bfloat16 to optimize for RTX 5070 Ti (Blackwell) VRAM
            base_model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
                model_id,
                torch_dtype=torch.bfloat16,
                device_map=self.device
            )
            self.model = PeftModel.from_pretrained(base_model, lora_dir)
            self.model.eval()
            
            self.processor = AutoProcessor.from_pretrained(model_id, min_pixels=112 * 28 * 28, max_pixels=768 * 28 * 28)
            self._initialized = True
            print('Qwen LoRA model loaded successfully.')
            return True
        except Exception as e:
            print(f'Error loading Qwen LoRA model: {e}')
            return False

    def extract_score(self, pil_image: Image.Image) -> ScoreResult:
        """Extracts the scoreboard data using the fine-tuned JSON format."""
        from ocr_utils import ScoreResult
        import json
        import re
        from PIL import ImageOps
        from qwen_vl_utils import process_vision_info
        
        if not hasattr(self, "model") or not self.model or not hasattr(self, "processor") or not self.processor:
            self.initialize()
            
        w, h = pil_image.size
        
        # Anamorphic Horizontal Pre-Scaling: Expand dense 8px glyphs past the 14x14 ViT patch limit
        new_w = int(w * 2.0)
        from PIL import Image
        pil_image = pil_image.resize((new_w, h), resample=Image.Resampling.LANCZOS)
        
        # Apply vertical padding for 2D-RoPE spatial anchors
        pad_total = max(0, 112 - h)
        if pad_total > 0:
            pad_top = pad_total // 2
            pad_bottom = pad_total - pad_top
            pil_image = ImageOps.expand(pil_image, border=(0, pad_top, 0, pad_bottom), fill=(30, 30, 30))

        INFERENCE_PROMPT = """Examine this World Table Tennis (WTT) broadcast scoreboard image. Extract the player names and scores into a valid JSON object matching this schema:
{
  "row_1_name": "string",
  "row_1_sets": integer,
  "row_1_points": integer,
  "row_2_name": "string",
  "row_2_sets": integer,
  "row_2_points": integer
}"""

        conversation = [{
            "role": "user",
            "content": [
                {"type": "image", "image": pil_image},
                {"type": "text", "text": INFERENCE_PROMPT},
            ],
        }]

        text_input = self.processor.apply_chat_template(
            conversation, tokenize=False, add_generation_prompt=True
        )
        image_inputs, video_inputs = process_vision_info(conversation)
        inputs = self.processor(
            text=[text_input], images=image_inputs, videos=video_inputs, padding=True, return_tensors="pt"
        ).to(self.model.device)

        bad_words = ["RUZIMUKHMMAD", "AFRAKTEH", "DIMITTAR", "DIMMITAR", "DIMIMITAR"]
        bad_words_ids = self.processor.tokenizer(bad_words, add_special_tokens=False).input_ids

        with torch.no_grad():
            output_ids = self.model.generate(
                **inputs,
                max_new_tokens=90,  
                do_sample=False,
                temperature=None,
                top_p=None,
                top_k=None,
                bad_words_ids=bad_words_ids,
            )

        generated_ids = output_ids[0][inputs.input_ids.shape[1] :]
        response_text = self.processor.decode(generated_ids, skip_special_tokens=True)

        cleaned_json_str = re.sub(
            r"^```json\s*|\s*```$", "", response_text.strip(), flags=re.MULTILINE
        )

        try:
            data = json.loads(cleaned_json_str)
            return ScoreResult(
                success=True,
                player1=data.get("row_1_name", ""),
                set1=data.get("row_1_sets", 0),
                game1=data.get("row_1_points", 0),
                player2=data.get("row_2_name", ""),
                set2=data.get("row_2_sets", 0),
                game2=data.get("row_2_points", 0)
            )
        except json.JSONDecodeError:
            match = re.search(r"\{.*\}", response_text, re.DOTALL)
            if match:
                try:
                    data = json.loads(match.group(0))
                    return ScoreResult(
                        success=True,
                        player1=data.get("row_1_name", ""),
                        set1=data.get("row_1_sets", 0),
                        game1=data.get("row_1_points", 0),
                        player2=data.get("row_2_name", ""),
                        set2=data.get("row_2_sets", 0),
                        game2=data.get("row_2_points", 0)
                    )
                except Exception:
                    pass
            return ScoreResult(success=False, error=f"JSON Parse Error. Output: {response_text}")
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
            'format': 'bv*[height=480]/bv*[height=720]/bv*[height=1080]/bv*[height<=1080]',
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

    def list_recent_streams(self, num_videos: int, cookies_file: str=None) -> None:
        try:
            import yt_dlp
        except ImportError:
            print("Error: yt-dlp not installed. Run: pip install yt-dlp")
            return
            
        print(f"Fetching last {num_videos} streams from World Table Tennis channel...")
        ydl_opts = {
            'quiet': True,
            'extract_flat': 'in_playlist',
            'playlistend': num_videos,
            'remote_components': ['ejs:github']
        }
        
        if cookies_file and os.path.exists(cookies_file):
            ydl_opts['cookiefile'] = cookies_file
            
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                url = "https://www.youtube.com/@WTTGlobal/streams"
                info = ydl.extract_info(url, download=False)
                
                if info and 'entries' in info:
                    print("\nRecent WTT Streams:")
                    print("-" * 80)
                    for i, entry in enumerate(info['entries'], 1):
                        vid = entry.get('id', 'Unknown ID')
                        title = entry.get('title', 'Unknown Title')
                        print(f"{i:2d}. {vid} | {title}")
                    print("-" * 80)
                else:
                    print("No entries found in the channel streams.")
        except Exception as e:
            print(f"Error fetching streams: {e}")

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
