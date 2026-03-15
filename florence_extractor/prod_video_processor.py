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
from transformers import AutoProcessor, AutoModelForCausalLM
from ocr_utils import parse_score, ScoreResult, normalize_text, is_similar
from wtt_video_processor import WttVideoProcessor

BACKEND_PYTORCH = 'pytorch-cpu'
BACKEND_OPENVINO = 'openvino'
ALL_BACKENDS = [BACKEND_PYTORCH, BACKEND_OPENVINO]

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
    cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', video_path]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return float(result.stdout.strip())
    except (subprocess.CalledProcessError, ValueError) as e:
        print(f'Error getting video duration: {e}')
        return 0

def _global_extract_frame(video_path: str, timestamp_seconds: float, output_path: str) -> bool:
    """Extract a single frame from video at given timestamp."""
    timestamp_str = format_timestamp(timestamp_seconds)
    cmd = ['ffmpeg', '-y', '-ss', timestamp_str, '-i', video_path, '-frames:v', '1', '-q:v', '2', output_path]
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
                print(f"Mapped hardware '{target_name}' to PyTorch index cuda:{i}")
                return f'cuda:{i}'
        print(f"Warning: Could not find GPU matching name '{target_name}'. Falling back to ID.")
    if getattr(args, 'cuda_device_id', None) is not None:
        if 0 <= args.cuda_device_id < num_devices:
            return f'cuda:{args.cuda_device_id}'
        else:
            print(f'Error: Specified --cuda_device_id {args.cuda_device_id} is out of range. Available devices: 0 to {num_devices - 1}.')
            sys.exit(1)
    if num_devices == 1:
        return 'cuda:0'
    print('Multiple CUDA devices found. Please specify which one to use with --cuda_device_id <number>')
    for i in range(num_devices):
        print(f'  Device {i}: {torch.cuda.get_device_name(i)}')
    sys.exit(1)

def get_default_backend() -> str:
    """Get default backend - use openvino if available, else pytorch."""
    try:
        import openvino
        return BACKEND_OPENVINO
    except ImportError:
        return BACKEND_PYTORCH

class ScoreExtractor:
    """Handles score extraction using Florence-2 OCR model."""

    def __init__(self, backend: str=None, device: str='cpu'):
        self.model = None
        self.processor = None
        self.device = device
        self._initialized = False
        self._backend = backend or get_default_backend()
        self._ov_model = None

    def initialize(self) -> bool:
        """Load the Florence-2 model using selected backend."""
        if self._initialized:
            return True
        script_dir = os.path.dirname(os.path.abspath(__file__))
        self._model_path = os.path.join(script_dir, 'florence2-tt-finetuned')
        if self._backend == BACKEND_OPENVINO:
            return self._initialize_openvino()
        else:
            return self._initialize_pytorch()

    def _initialize_pytorch(self) -> bool:
        """Initialize PyTorch backend (original working code)."""
        import torch
        dev_info = ''
        if str(self.device).startswith('cuda'):
            try:
                idx = getattr(self.device, 'index', None)
                if idx is None and ':' in str(self.device):
                    idx = int(str(self.device).split(':')[1])
                elif idx is None:
                    idx = 0
                dev_info = f' - {torch.cuda.get_device_name(idx)}'
            except Exception:
                pass
        print(f'Loading Florence-2 model (PyTorch on {self.device}{dev_info})...')
        try:
            self.processor = AutoProcessor.from_pretrained(self._model_path, trust_remote_code=True)
            self.model = AutoModelForCausalLM.from_pretrained(self._model_path, trust_remote_code=True, attn_implementation='eager').to(self.device)
            self._initialized = True
            print('Model loaded successfully.')
            return True
        except Exception as e:
            print(f'Error loading Florence-2 model: {e}')
            return False

    def _initialize_openvino(self) -> bool:
        """Initialize OpenVINO backend for GPU acceleration."""
        print('Loading Florence-2 model (OpenVINO GPU)...')
        try:
            from backends.ov_florence2_helper import OVFlorence2Model
            from pathlib import Path
            ov_model_dir = Path(self._model_path) / 'openvino'
            self.processor = AutoProcessor.from_pretrained(ov_model_dir, trust_remote_code=True)
            self._ov_model = OVFlorence2Model(ov_model_dir, device='GPU', ov_config={})
            self._initialized = True
            print('Model loaded successfully (OpenVINO GPU).')
            return True
        except FileNotFoundError as e:
            print(f'Error: {e}')
            return False
        except Exception as e:
            print(f'Error loading OpenVINO model: {e}')
            print('Falling back to PyTorch...')
            self._backend = BACKEND_PYTORCH
            return self._initialize_pytorch()

    def extract_score(self, pil_image: Image.Image) -> ScoreResult:
        """Extract score from a cropped PIL image."""
        if not self._initialized:
            return ScoreResult(success=False, error='Model not initialized')
        try:
            if self._backend == BACKEND_OPENVINO:
                generated_text = self._extract_openvino(pil_image)
            else:
                generated_text = self._extract_pytorch(pil_image)
            return parse_score(generated_text)
        except Exception as e:
            return ScoreResult(success=False, error=str(e))

    def _extract_pytorch(self, pil_image: Image.Image) -> str:
        """Extract text using PyTorch backend (original working code)."""
        prompt = '<WTT_SCORE>'
        inputs = self.processor(text=prompt, images=pil_image, return_tensors='pt').to(self.device)
        generated_ids = self.model.generate(input_ids=inputs['input_ids'], pixel_values=inputs['pixel_values'], max_new_tokens=1024, num_beams=1, do_sample=False, early_stopping=False, use_cache=False)
        return self.processor.batch_decode(generated_ids, skip_special_tokens=True)[0]

    def _extract_openvino(self, pil_image: Image.Image) -> str:
        """Extract text using OpenVINO backend (GPU accelerated)."""
        prompt = '<WTT_SCORE>'
        inputs = self.processor(text=prompt, images=pil_image, return_tensors='pt')
        generated_ids = self._ov_model.generate(input_ids=inputs['input_ids'], pixel_values=inputs['pixel_values'], max_new_tokens=1024, num_beams=1, do_sample=False, early_stopping=False)
        return self.processor.batch_decode(generated_ids, skip_special_tokens=True)[0]

class ProdWttVideoProcessor(WttVideoProcessor):

    def __init__(self, backend: str=None, device: str='cpu', cropped_dir: str=None):
        self.extractor = ScoreExtractor(backend=backend, device=device)
        self.cropped_dir = cropped_dir

    def fetch_video_info(self, youtube_url: str, cookies_file: Optional[str]=None) -> Tuple[Optional[str], Optional[str]]:
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
        ydl_opts = {'quiet': True, 'no_warnings': True, 'skip_download': True, 'extractor_args': {'youtubetab': ['approximate_date']}, 'remote_components': ['ejs:github']}
        if cookies_file:
            if os.path.exists(cookies_file):
                ydl_opts['cookiefile'] = cookies_file
            else:
                raise FileNotFoundError(f'Could not find requested cookie file at: {cookies_file}')
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

    def download_video(self, youtube_url: str, output_dir: str, cookies_file: Optional[str]=None) -> Optional[str]:
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
        video_path = os.path.join(output_dir, f'{video_id}.webm')
        if os.path.exists(video_path):
            print(f'Video already downloaded: {video_path}')
            return video_path
        ydl_opts = {'format': 'bv*[height<=480]', 'outtmpl': video_path, 'quiet': False, 'no_warnings': False, 'retries': 100, 'remote_components': ['ejs:github']}
        if cookies_file:
            if os.path.exists(cookies_file):
                ydl_opts['cookiefile'] = cookies_file
            else:
                raise FileNotFoundError(f'Could not find requested cookie file at: {cookies_file}')
        print(f'Downloading YouTube video at 480p (video only)...')
        print(f'  URL: {youtube_url}')
        start_time = time.time()
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                ydl.download([youtube_url])
            download_time = time.time() - start_time
            if os.path.exists(video_path):
                file_size = os.path.getsize(video_path) / (1024 * 1024)
                print(f'Download complete: {video_path}')
                print(f'  Size: {file_size:.1f} MB')
                print(f'  Time: {download_time:.1f}s')
                return video_path
            else:
                for ext in ['.mp4', '.mkv', '.webm']:
                    alt_path = video_path.rsplit('.', 1)[0] + ext
                    if os.path.exists(alt_path):
                        return alt_path
                print('Error: Video file not found after download.')
                return None
        except Exception as e:
            print(f'Error downloading video: {e}')
            traceback.print_exc()
            return None


    
    def extract_image(self, video_path: str, timestamp_seconds: float, output_path: str) -> bool:
        return _global_extract_frame(video_path, timestamp_seconds, output_path)

    def get_scoreboard(self, image_path: str, actual_timestamp: float=0.0) -> Tuple[ScoreResult, str]:
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


    def get_videos_after(self, after_video_id: str, batch_size: int=200, max_batches: int=10) -> List[dict]:
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
            print(f"Error: Video '{after_video_id}' does not exist or is not accessible.")
            return []
        playlist_url = 'https://www.youtube.com/@WTTGlobal/streams'
        for batch_num in range(1, max_batches + 1):
            total_videos = batch_size * batch_num
            print(f'Fetching playlist (up to {total_videos} videos, batch {batch_num}/{max_batches})...')
            ydl_opts = {'quiet': True, 'no_warnings': True, 'extract_flat': 'in_playlist', 'playlistend': total_videos, 'extractor_args': {'youtubetab': {'approximate_date': ['']}}, 'remote_components': ['ejs:github']}
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
                        if entry.get('live_status') == 'was_live':
                            ts = entry.get('timestamp')
                            if ts is not None:
                                entry['upload_date'] = str(int(ts))
                            newer_videos.append(entry)
                    if found_cutoff:
                        return newer_videos
                    if len(entries) < total_videos:
                        print(f"Video '{after_video_id}' not found in playlist ({len(entries)} videos checked)")
                        return []
                    print(f'Video not found in first {total_videos} entries, fetching more...')
            except Exception as e:
                print(f'Error fetching streams: {e}')
                return []
        print(f"Video '{after_video_id}' not found after checking {batch_size * max_batches} videos")
        return []

    def get_video_duration(self, video_path: str) -> float:
        """Get video duration in seconds using ffprobe."""
        cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', video_path]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return float(result.stdout.strip())
        except (subprocess.CalledProcessError, ValueError) as e:
            print(f'Error getting video duration: {e}')
            return 0
