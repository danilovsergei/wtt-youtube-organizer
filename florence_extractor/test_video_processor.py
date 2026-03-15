import os
import uuid
import json
from typing import Optional, List, Tuple, Dict, Any
from wtt_video_processor import WttVideoProcessor
from ocr_utils import ScoreResult

class TestWttVideoProcessor(WttVideoProcessor):
    def __init__(self, golden_json_path: str):
        self.golden_json_path = golden_json_path
        self.scoreboards = {}
        self.max_duration = 0
        
        # Load the golden dataset
        if os.path.exists(golden_json_path):
            with open(golden_json_path, 'r') as f:
                data = json.load(f)
                for sec_str, info in data.items():
                    sec = int(sec_str)
                    if sec > self.max_duration:
                        self.max_duration = sec
                    
                    if not info or (info.get("player1", "") == "" and info.get("player2", "") == ""):
                        # Empty frame / No names detected
                        self.scoreboards[sec] = ScoreResult(success=False, error="No scoreboard detected")
                    else:
                        # Only consider it a success if we got actual scores
                        g1 = info.get("p1_points", -1)
                        g2 = info.get("p2_points", -1)
                        
                        if g1 == -1 or g2 == -1:
                            self.scoreboards[sec] = ScoreResult(success=False, error="Incomplete score digits found")
                        else:
                            self.scoreboards[sec] = ScoreResult(
                                success=True,
                                player1=info.get("player1", ""),
                                player2=info.get("player2", ""),
                                set1=info.get("p1_sets", -1),
                                set2=info.get("p2_sets", -1),
                                game1=g1,
                                game2=g2,
                                error=""
                            )
        else:
            print(f"Warning: Golden JSON not found at {golden_json_path}")

    def download_video(self, url: str, output_dir: str, cookies_file: Optional[str]=None) -> Optional[str]:
        fake_path = os.path.join(output_dir, 'fake_video.mp4')
        with open(fake_path, 'w') as f:
            f.write('fake video data')
        return fake_path

    def fetch_video_info(self, url: str, cookies_file: Optional[str]=None) -> Tuple[Optional[str], Optional[str]]:
        return ('Test Video Title', '1704067200') # Jan 1 2024

    def get_videos_after(self, after_video_id: str, max_videos: int=200, cookies_file: Optional[str]=None) -> List[dict]:
        return []

    def extract_image(self, video_path: str, timestamp_seconds: float, output_path: str) -> bool:
        # Hermetic mode: just touch the file so code doesn't crash if it checks for existence
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, 'w') as f:
            f.write('fake image data')
        return True

    def get_scoreboard(self, image_path: str, actual_timestamp: float=0.0) -> Tuple[ScoreResult, str]:
        ts = int(actual_timestamp)
        res = self.scoreboards.get(ts, ScoreResult(success=False, error='No fake score for this timestamp'))
        
        # We don't need a real cropped path for pure logic testing
        return (res, "fake_cropped_path.jpg")

    def get_video_duration(self, video_path: str) -> float:
        return float(self.max_duration + 10) # Pad slightly past last mapped frame

    def initialize_scoreboard_model(self) -> bool:
        return True

    def validate_video_exists(self, video_id: str) -> bool:
        return True

    def list_recent_streams(self, num_videos: int, cookies_file: Optional[str]=None) -> None:
        pass
