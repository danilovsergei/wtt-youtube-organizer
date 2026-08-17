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
        
        with patch("os.remove") as mock_remove:
            result = self.processor.download_video("https://youtube.com/watch?v=123", self.test_dir)
            
            # The script should accept the large file and return the path
            self.assertIsNotNone(result)
            self.assertFalse(mock_remove.called)

if __name__ == '__main__':
    unittest.main()

