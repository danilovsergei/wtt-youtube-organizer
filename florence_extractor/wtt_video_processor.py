import abc
from typing import Optional, List, Tuple, Dict, Any

class WttVideoProcessor(abc.ABC):
    @abc.abstractmethod
    def download_video(self, url: str, output_dir: str, cookies_file: Optional[str] = None) -> Optional[str]:
        pass

    @abc.abstractmethod
    def fetch_video_info(self, url: str, cookies_file: Optional[str] = None) -> Tuple[Optional[str], Optional[str]]:
        pass

    @abc.abstractmethod
    def get_videos_after(self, after_video_id: str, max_videos: int = 200, cookies_file: Optional[str] = None) -> List[Dict[str, Any]]:
        pass

    @abc.abstractmethod
    def extract_image(self, video_path: str, timestamp_seconds: float, output_path: str) -> bool:
        pass

    @abc.abstractmethod
    def get_scoreboard(self, image_path: str, actual_timestamp: float = 0.0) -> Tuple[Any, str]:
        pass

    @abc.abstractmethod
    def get_video_duration(self, video_path: str) -> float:
        pass

    @abc.abstractmethod
    def initialize_scoreboard_model(self) -> bool:
        pass

    @abc.abstractmethod
    def validate_video_exists(self, video_id: str) -> bool:
        pass

        pass
