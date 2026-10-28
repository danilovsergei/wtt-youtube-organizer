import abc
from typing import Optional, List, Tuple, Dict, Any

class WttVideoProcessor(abc.ABC):
    @staticmethod
    def classify_youtube_error(err_msg: str) -> Tuple[str, str]:
        """
        Classifies YouTube / yt-dlp errors into (error_code, error_category).
        Categories:
          - 'permanent': Truly deleted, private, or removed. Queue should discard.
          - 'retryable': Transient, archiving live stream, premiere, or network error. Queue should retry.
          - 'bot_blocked': Bot challenge or sign-in required. Queue should retain.
        """
        if not err_msg:
            return ('UNKNOWN_ERROR', 'retryable')

        err_lower = str(err_msg).lower()

        # 1. Bot check
        bot_keywords = [
            'sign in to confirm',
            'not a bot',
            "confirm you're not a bot",
            'confirm you’re not a bot',
            'bot challenge',
            'captcha',
            'too many requests',
            'http error 429',
        ]
        if any(k in err_lower for k in bot_keywords):
            return ('BOT_CONFIRMATION', 'bot_blocked')

        # 2. Temporary / Retryable states (Keep in queue)
        if 'this live event has ended' in err_lower:
            return ('LIVE_EVENT_PROCESSING', 'retryable')
        if 'this live event will begin in' in err_lower or 'live event has not started' in err_lower:
            return ('LIVE_EVENT_UPCOMING', 'retryable')
        if 'premieres in' in err_lower or 'premiere' in err_lower:
            return ('PREMIERE_UPCOMING', 'retryable')
        if 'is being processed' in err_lower or 'currently being processed' in err_lower:
            return ('PROCESSING', 'retryable')
        if any(k in err_lower for k in ['timed out', 'timeout', 'connection reset', 'network is unreachable', 'http error 5', 'service unavailable']):
            return ('NETWORK_TIMEOUT', 'retryable')

        # 3. Truly Permanent states (DELETED / PRIVATE / COPYRIGHT)
        if any(k in err_lower for k in ['has been removed by the uploader', 'has been removed', 'has been deleted', 'is deleted', 'video does not exist']):
            return ('VIDEO_DELETED', 'permanent')
        if any(k in err_lower for k in ['private video', 'is private']):
            return ('VIDEO_PRIVATE', 'permanent')
        if any(k in err_lower for k in ['copyright infringement', 'copyright claim', 'copyright']):
            return ('COPYRIGHT_TAKEDOWN', 'permanent')
        if 'account has been terminated' in err_lower or 'account associated with this video' in err_lower:
            return ('ACCOUNT_TERMINATED', 'permanent')
        if 'members-only content' in err_lower:
            return ('MEMBERS_ONLY', 'permanent')
        if 'uploader has not made this video available in your country' in err_lower:
            return ('GEO_RESTRICTED', 'permanent')

        if 'video unavailable' in err_lower:
            return ('VIDEO_UNAVAILABLE', 'permanent')

        # Default fallback to retryable
        return ('UNKNOWN_ERROR', 'retryable')

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
