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


    def test_tjmjcro8t94_golden_dataset(self):
        # 1. Resolve path to the golden dataset
        golden_json_path = os.path.join(
            os.path.dirname(__file__), 
            "testing/frames_tJMjCRO8t94/tJMjCRO8t94_golden.json"
        )
        
        # Verify the file exists
        self.assertTrue(
            os.path.exists(golden_json_path), 
            f"Golden dataset not found at {golden_json_path}"
        )
        
        # 2. Initialize the hermetic test processor
        processor = TestWttVideoProcessor(golden_json_path)
        
        # 3. Simulate downloading the video
        video_path = processor.download_video("tJMjCRO8t94", self.test_dir)
        
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
        
        # 6. Assertions based on the known golden data output
        self.assertEqual(len(matches), 4)
        
        # Match 1: SABINE WINTER vs WANG MANYU at 00:13:50 (830 seconds)
        m1 = matches[0]
        self.assertEqual(int(m1.timestamp_seconds), 830)
        self.assertEqual(m1.player1, "SABINE WINTER")
        self.assertEqual(m1.player2, "WANG MANYU")
        
        # Match 2: SUN YINGSHA vs CHEN YI at 01:11:44 (4304 seconds)
        m2 = matches[1]
        self.assertEqual(int(m2.timestamp_seconds), 4304)
        self.assertEqual(m2.player1, "SUN YINGSHA")
        self.assertEqual(m2.player2, "CHEN YI")

        # Match 3: LIN YUN-JU vs TRULS MOREGARD at 02:16:47 (8207 seconds)
        m3 = matches[2]
        self.assertEqual(int(m3.timestamp_seconds), 8207)
        self.assertEqual(m3.player1, "LIN YUN-JU")
        self.assertEqual(m3.player2, "TRULS MOREGARD")

        # Match 4: WANG CHUQIN vs FELIX LEBRUN at 03:22:41 (12161 seconds)
        m4 = matches[3]
        self.assertEqual(int(m4.timestamp_seconds), 12161)
        self.assertEqual(m4.player1, "WANG CHUQIN")
        self.assertEqual(m4.player2, "FELIX LEBRUN")


    def test_fgjela0mgje_golden_dataset(self):
        # 1. Resolve path to the golden dataset
        golden_json_path = os.path.join(
            os.path.dirname(__file__), 
            "testing/frames_FGjela0MgjE/FGjela0MgjE_golden.json"
        )
        
        # Verify the file exists
        self.assertTrue(
            os.path.exists(golden_json_path), 
            f"Golden dataset not found at {golden_json_path}"
        )
        
        # 2. Initialize the hermetic test processor
        processor = TestWttVideoProcessor(golden_json_path)
        
        # 3. Simulate downloading the video
        video_path = processor.download_video("FGjela0MgjE", self.test_dir)
        
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
        
        # 6. Assertions based on the known golden data output
        self.assertEqual(len(matches), 5)
        
        # Match 1: MIWA HARIMOTO vs WANG MANYU at 00:13:15 (795 seconds)
        m1 = matches[0]
        self.assertEqual(int(m1.timestamp_seconds), 795)
        self.assertEqual(m1.player1, "MIWA HARIMOTO")
        self.assertEqual(m1.player2, "WANG MANYU")
        
        # Match 2: LIN SHIDONG vs FELIX LEBRUN at 01:31:11 (5471 seconds)
        m2 = matches[1]
        self.assertEqual(int(m2.timestamp_seconds), 5471)
        self.assertEqual(m2.player1, "LIN SHIDONG")
        self.assertEqual(m2.player2, "FELIX LEBRUN")

        # Match 3: WANG YIDI vs SABINE WINTER at 02:34:15 (9255 seconds)
        m3 = matches[2]
        self.assertEqual(int(m3.timestamp_seconds), 9255)
        self.assertEqual(m3.player1, "WANG YIDI")
        self.assertEqual(m3.player2, "SABINE WINTER")

        # Match 4: WANG CHUQIN vs JANG WOOJIN at 03:26:49 (12409 seconds)
        m4 = matches[3]
        self.assertEqual(int(m4.timestamp_seconds), 12409)
        self.assertEqual(m4.player1, "WANG CHUQIN")
        self.assertEqual(m4.player2, "JANG WOOJIN")

        # Match 5: HAYATA / HARIMOTO vs SHIN / NAGASAKI at 04:19:59 (15599 seconds)
        m5 = matches[4]
        self.assertEqual(int(m5.timestamp_seconds), 15599)
        self.assertEqual(m5.player1, "HAYATA / HARIMOTO")
        self.assertEqual(m5.player2, "SHIN / NAGASAKI")

if __name__ == '__main__':
    unittest.main()
