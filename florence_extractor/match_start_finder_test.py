import os
import unittest
import shutil
import tempfile

from test_video_processor import TestWttVideoProcessor
from match_start_finder import MatchStartFinder

class TestMatchStartFinderHermetic(unittest.TestCase):
    def setUp(self):
        # Create a temporary directory for test outputs
        self.test_dir = tempfile.mkdtemp()
        
    def tearDown(self):
        # Clean up
        if os.path.exists(self.test_dir):
            shutil.rmtree(self.test_dir)

    def test_hjxfbulldro_golden_dataset(self):
        # 1. Resolve path to the golden dataset
        golden_json_path = os.path.join(
            os.path.dirname(__file__), 
            "testing/frames_hJXfBULLDro/hJXfBULLDro_golden.json"
        )
        
        # Verify the file exists so the test doesn't fail cryptically if moved
        self.assertTrue(
            os.path.exists(golden_json_path), 
            f"Golden dataset not found at {golden_json_path}"
        )
        
        # 2. Initialize the hermetic test processor
        processor = TestWttVideoProcessor(golden_json_path)
        
        # 3. Simulate downloading the video
        video_path = processor.download_video("hJXfBULLDro", self.test_dir)
        
        # 4. Initialize the MatchStartFinder with our mocked processor
        finder = MatchStartFinder(
            video_path=video_path,
            output_dir=self.test_dir,
            processor=processor
        )
        
        # 5. Run the core algorithm
        try:
            matches = finder.find_match_starts()
        finally:
            finder.cleanup()
        
        # 6. Assertions based on the known golden data
        # There should be exactly two matches discovered
        self.assertEqual(len(matches), 2)
        
        # Match 1: SUN YINGSHA vs WANG MANYU at exactly 00:16:33 (993 seconds)
        m1 = matches[0]
        self.assertEqual(int(m1.timestamp_seconds), 993)
        self.assertEqual(m1.player1, "SUN YINGSHA")
        self.assertEqual(m1.player2, "WANG MANYU")
        
        # Match 2: WANG CHUQIN vs LIN YUN-JU at exactly 01:54:14 (6854 seconds)
        m2 = matches[1]
        self.assertEqual(int(m2.timestamp_seconds), 6854)
        self.assertEqual(m2.player1, "WANG CHUQIN")
        self.assertEqual(m2.player2, "LIN YUN-JU")

if __name__ == '__main__':
    unittest.main()
