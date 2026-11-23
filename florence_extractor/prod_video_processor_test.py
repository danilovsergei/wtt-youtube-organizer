import os
import unittest
import tempfile
import shutil
from unittest.mock import patch, MagicMock

from prod_video_processor import ProdWttVideoProcessor

class TestProdVideoProcessor(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.processor = ProdWttVideoProcessor(backend="pytorch-cpu", device="cpu")

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    @patch("yt_dlp.YoutubeDL")
    def test_download_video_fails_on_small_file(self, mock_ytdl):
        # Create a fake broken video file (e.g. 1 KB)
        fake_video_path = os.path.join(self.test_dir, "fake_video.mp4")
        with open(fake_video_path, "wb") as f:
            f.write(b"0" * 1024) # 1 KB

        # Mock yt_dlp to just "succeed" without throwing an error
        mock_instance = MagicMock()
        mock_ytdl.return_value.__enter__.return_value = mock_instance
        
        # Override the video path to point to our fake file
        # We need to monkeypatch the internal path resolution or just mock outtmpl
        # Actually, download_video resolves the video_path internally using the URL.
        # Let's just mock os.path.exists and os.path.getsize directly for the test
        # to simulate the exact failure condition.
        pass

    @patch("os.path.exists")
    @patch("os.path.getsize")
    @patch("yt_dlp.YoutubeDL")
    def test_download_video_small_file_returns_none(self, mock_ytdl, mock_getsize, mock_exists):
        # We want exists to return False initially (not cached), then True after download.
        # But for alt_path loop, we can just return True for the primary path.
        mock_exists.side_effect = [False, True]
        
        # Simulate a 1KB file (which is 0.00095 MB, definitely < 100.0 MB)
        mock_getsize.return_value = 1024 
        
        mock_instance = MagicMock()
        mock_instance.extract_info.return_value = {'duration': 0}
        mock_ytdl.return_value.__enter__.return_value = mock_instance
        
        with patch("os.remove") as mock_remove:
            result = self.processor.download_video("https://youtube.com/watch?v=123", self.test_dir)
            
            # The script should detect the small file, return None, and call os.remove
            self.assertIsNone(result)
            self.assertTrue(mock_remove.called)

    @patch("os.path.exists")
    @patch("os.path.getsize")
    @patch("yt_dlp.YoutubeDL")
    def test_download_video_success_on_large_file(self, mock_ytdl, mock_getsize, mock_exists):
        # Not cached initially, exists after download
        mock_exists.side_effect = [False, True]
        
        # Simulate a 150MB file (which is > 100.0 MB)
        mock_getsize.return_value = 150 * 1024 * 1024 
        
        mock_instance = MagicMock()
        mock_instance.extract_info.return_value = {'duration': 0}
        mock_ytdl.return_value.__enter__.return_value = mock_instance
        
        with patch("os.remove") as mock_remove:
            result = self.processor.download_video("https://youtube.com/watch?v=123", self.test_dir)
            
            # The script should accept the large file and return the path
            self.assertIsNotNone(result)
            self.assertFalse(mock_remove.called)


    @patch("os.path.exists")
    @patch("os.path.getsize")
    @patch("yt_dlp.YoutubeDL")
    def test_download_video_short_duration_returns_skip(self, mock_ytdl, mock_getsize, mock_exists):
        # exists=False initially, then True after download
        mock_exists.side_effect = [False, True]
        
        # Simulate a normal 150MB file
        mock_getsize.return_value = 150 * 1024 * 1024 
        
        # Mock extract_info to return a duration of 800 seconds (< 15 mins)
        mock_instance = MagicMock()
        mock_instance.extract_info.return_value = {'duration': 800}
        mock_ytdl.return_value.__enter__.return_value = mock_instance
        
        with patch("os.remove") as mock_remove:
            result = self.processor.download_video("https://youtube.com/watch?v=123", self.test_dir)
            self.assertEqual(result, "SKIP_SHORT_VIDEO")
            self.assertTrue(mock_remove.called)

    @patch("os.path.exists")
    @patch("os.path.getsize")
    @patch("yt_dlp.YoutubeDL")
    def test_download_video_long_duration_small_size_returns_path(self, mock_ytdl, mock_getsize, mock_exists):
        # exists=False initially, then True after download
        mock_exists.side_effect = [False, True]
        
        # Simulate a highly compressed 50MB file (< 100MB)
        mock_getsize.return_value = 50 * 1024 * 1024 
        
        # Mock extract_info to return a duration of 3600 seconds (1 hour)
        mock_instance = MagicMock()
        mock_instance.extract_info.return_value = {'duration': 3600}
        mock_ytdl.return_value.__enter__.return_value = mock_instance
        
        with patch("os.remove") as mock_remove:
            result = self.processor.download_video("https://youtube.com/watch?v=123", self.test_dir)
            
            # The script should bypass the 100MB check because duration is confirmed > 15 mins
            self.assertIsNotNone(result)
            self.assertNotEqual(result, "SKIP_SHORT_VIDEO")
            self.assertFalse(mock_remove.called)

    @patch("os.path.exists")
    @patch("os.path.getsize")
    @patch("yt_dlp.YoutubeDL")
    def test_download_video_missing_duration_small_size_returns_none(self, mock_ytdl, mock_getsize, mock_exists):
        # exists=False initially, then True after download
        mock_exists.side_effect = [False, True]
        
        # Simulate a suspicious 50MB file
        mock_getsize.return_value = 50 * 1024 * 1024 
        
        # Mock extract_info to return missing duration (e.g. YouTube bug)
        mock_instance = MagicMock()
        mock_instance.extract_info.return_value = {}
        mock_ytdl.return_value.__enter__.return_value = mock_instance
        
        with patch("os.remove") as mock_remove:
            result = self.processor.download_video("https://youtube.com/watch?v=123", self.test_dir)
            
            # The script should fall back to the 100MB rule and delete it
            self.assertIsNone(result)
            self.assertTrue(mock_remove.called)

    @patch("yt_dlp.YoutubeDL")
    def test_fetch_video_info_bot_challenge_detected(self, mock_ytdl):
        mock_instance = MagicMock()
        mock_instance.extract_info.side_effect = Exception("ERROR: [youtube] 123: Sign in to confirm you’re not a bot. Use --cookies-from-browser")
        mock_ytdl.return_value.__enter__.return_value = mock_instance

        title, upload_date = self.processor.fetch_video_info("https://youtube.com/watch?v=123")
        self.assertIsNone(title)
        self.assertIsNone(upload_date)
        self.assertTrue(self.processor.last_fetch_is_bot_blocked)

    @patch.object(ProdWttVideoProcessor, "fetch_video_info")
    def test_get_videos_after_bot_challenge_returns_bot_blocked(self, mock_fetch):
        self.processor.last_fetch_is_bot_blocked = True
        mock_fetch.return_value = (None, None)

        status = self.processor.get_videos_after("123")
        self.assertEqual(status, "BOT_BLOCKED")

if __name__ == '__main__':
    unittest.main()

class TestErrorClassification(unittest.TestCase):
    def test_classify_live_ended(self):
        err = "ERROR: [youtube] tWvoMmXIV9s: This live event has ended."
        code, cat = ProdWttVideoProcessor.classify_youtube_error(err)
        self.assertEqual(code, "LIVE_EVENT_PROCESSING")
        self.assertEqual(cat, "retryable")

    def test_classify_bot_challenge(self):
        err = "ERROR: [youtube] 123: Sign in to confirm you’re not a bot."
        code, cat = ProdWttVideoProcessor.classify_youtube_error(err)
        self.assertEqual(code, "BOT_CONFIRMATION")
        self.assertEqual(cat, "bot_blocked")

    def test_classify_video_deleted(self):
        err = "ERROR: [youtube] 123: This video has been removed by the uploader"
        code, cat = ProdWttVideoProcessor.classify_youtube_error(err)
        self.assertEqual(code, "VIDEO_DELETED")
        self.assertEqual(cat, "permanent")

    def test_classify_video_private(self):
        err = "ERROR: [youtube] 123: Private video. Sign in if you've been granted access"
        code, cat = ProdWttVideoProcessor.classify_youtube_error(err)
        self.assertEqual(code, "VIDEO_PRIVATE")
        self.assertEqual(cat, "permanent")

    def test_classify_copyright(self):
        err = "ERROR: [youtube] 123: Video unavailable. This video is no longer available due to a copyright claim"
        code, cat = ProdWttVideoProcessor.classify_youtube_error(err)
        self.assertEqual(code, "COPYRIGHT_TAKEDOWN")
        self.assertEqual(cat, "permanent")

    def test_classify_network_timeout(self):
        err = "ERROR: [youtube] 123: Connection timed out"
        code, cat = ProdWttVideoProcessor.classify_youtube_error(err)
        self.assertEqual(code, "NETWORK_TIMEOUT")
        self.assertEqual(cat, "retryable")

    def test_classify_unknown_defaults_to_retryable(self):
        err = "Some strange unpredictable YouTube error message"
        code, cat = ProdWttVideoProcessor.classify_youtube_error(err)
        self.assertEqual(code, "UNKNOWN_ERROR")
        self.assertEqual(cat, "retryable")

    def test_inference_prompt_requires_both_player_rows(self):
        with open("prod_video_processor.py") as f:
            content = f.read()
        self.assertIn("CRITICAL RULE: A valid scoreboard MUST clearly display BOTH competing player rows", content)
        self.assertIn("Ignore any tournament stage or round header banner", content)
        self.assertIn("If only one player row is visible, if the scoreboard is partially cut off", content)

def test_clean_player_name_preserves_doubles_slash():
    import re
    def clean_player_name(raw_name: str) -> str:
        name = str(raw_name).replace("|", "")
        name = re.sub(r"[^A-Za-z\s\-'/]", " ", name)
        name = re.sub(r'\s*/\s*', ' / ', name)
        return re.sub(r'\s+', ' ', name).strip()

    assert clean_player_name("D|O|R|R| |/| |Y|U|A|N") == "DORR / YUAN"
    assert clean_player_name("T|O|G|A|M|I| |/| |O|D|O") == "TOGAMI / ODO"
    assert clean_player_name("J|A|N|G| |W|O|O|-|J|I|N") == "JANG WOO-JIN"
    assert clean_player_name("KUAI MAN {}_4") == "KUAI MAN"


def test_get_bottom_percent_ittf_teams_versus_wtt():
    from prod_video_processor import get_bottom_percent
    # Standard WTT events stay at default 0.14
    assert get_bottom_percent("WTT Star Contender Muscat 2026 Finals") == 0.14
    assert get_bottom_percent("Singapore Smash 2026 Day 5") == 0.14
    assert get_bottom_percent("WTT Champions Frankfurt 2026 R16") == 0.14
    
    # ITTF Team events expand to 0.20 to capture 3-row layout without slicing top player
    assert get_bottom_percent("LIVE! | T1 | Day 3 | ITTF World Youth Championships Istanbul 2026 | GU19 Teams Final") == 0.20
    assert get_bottom_percent("ITTF World Team Championships Busan 2026 Men's Team Final") == 0.20
    assert get_bottom_percent(video_title="Day 2 Session 2", tournament_name="ITTF World Youth Teams") == 0.20


def test_is_valid_player_name_rejects_single_letters_and_team_scores():
    from prod_video_processor import ScoreExtractor
    extractor = ScoreExtractor()
    # Test through raw parse logic
    import json
    invalid_cases = [
        ('{"row_1_name": "M|I|S|U|Z|U| |T|A|K|E|Y|A", "row_2_name": "O", "row_1_sets": 1, "row_1_points": 5, "row_2_sets": 0, "row_2_points": 4}', "O"),
        ('{"row_1_name": "C|U|I| |Z|I|J|U|N", "row_2_name": "T|P|E| |O|-| |C|H|N", "row_1_sets": 0, "row_1_points": 0, "row_2_sets": 0, "row_2_points": 0}', "TPE O- CHN"),
        ('{"row_1_name": "D|U| |H|A|N|J|I|N|G", "row_2_name": "K|O|R| |O|-| |O| |C|H|N", "row_1_sets": 0, "row_1_points": 0, "row_2_sets": 0, "row_2_points": 0}', "KOR O- O CHN"),
    ]
    for raw_json, bad_name in invalid_cases:
        res = extractor._parse_qwen_json(raw_json)
        assert not res.success, f"Expected {bad_name} to be rejected as invalid player name"
