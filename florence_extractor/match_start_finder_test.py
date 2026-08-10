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


    def test_missing_break_fallback(self):
        # Simulate a scenario where there is NO empty break between matches
        # Match 1 ends, then immediately Match 2 starts.
        # But we only sample every 180s (3 mins).
        # Let's say coarse samples are:
        # 11700 (3:15:00): Player A vs Player B
        # 11880 (3:18:00): Player C vs Player D
        
        # We need Match C vs D to start at 11818 (3:16:58)
        
        synthetic_data = {}
        # At 11700, Match 1
        synthetic_data["11340"] = {"player1": "PLAYER A", "player2": "PLAYER B", "p1_sets": 2, "p2_sets": 1, "p1_points": 1, "p2_points": 1}
        synthetic_data["11520"] = {"player1": "PLAYER A", "player2": "PLAYER B", "p1_sets": 2, "p2_sets": 1, "p1_points": 5, "p2_points": 5}
        synthetic_data["11700"] = {"player1": "PLAYER A", "player2": "PLAYER B", "p1_sets": 2, "p2_sets": 1, "p1_points": 10, "p2_points": 8}
        
        # Match 1 ends somewhere. Match 2 starts at 11818.
        # So at 11818, it's 0:0
        synthetic_data["11818"] = {"player1": "AN JAEHYUN", "player2": "ALEXIS LEBRUN", "p1_sets": 0, "p2_sets": 0, "p1_points": 0, "p2_points": 0}
        
        # At 11880, it's Match 2. It has been 62 seconds = ~4 points.
        synthetic_data["11880"] = {"player1": "AN JAEHYUN", "player2": "ALEXIS LEBRUN", "p1_sets": 0, "p2_sets": 0, "p1_points": 2, "p2_points": 2}
        synthetic_data["12060"] = {"player1": "AN JAEHYUN", "player2": "ALEXIS LEBRUN", "p1_sets": 0, "p2_sets": 0, "p1_points": 5, "p2_points": 5}
        synthetic_data["12240"] = {"player1": "AN JAEHYUN", "player2": "ALEXIS LEBRUN", "p1_sets": 0, "p2_sets": 0, "p1_points": 10, "p2_points": 8}

        # Let's fill out binary search points between 11700 and 11880 that it might hit
        # mid = 11790 (before match 2). Let's say it's still Match 1 graphic.
        synthetic_data["11790"] = {"player1": "PLAYER A", "player2": "PLAYER B", "p1_sets": 3, "p2_sets": 1, "p1_points": 11, "p2_points": 8}
        # mid between 11790 and 11880 = 11835. Match 2 started, 17 seconds in = 1 point.
        synthetic_data["11835"] = {"player1": "AN JAEHYUN", "player2": "ALEXIS LEBRUN", "p1_sets": 0, "p2_sets": 0, "p1_points": 1, "p2_points": 0}
        # mid between 11790 and 11835 = 11812.5 -> 11812. No score
        synthetic_data["11812"] = {}
        # mid between 11812 and 11835 = 11823.5 -> 11823. 0:0
        synthetic_data["11823"] = {"player1": "AN JAEHYUN", "player2": "ALEXIS LEBRUN", "p1_sets": 0, "p2_sets": 0, "p1_points": 0, "p2_points": 0}
        # mid between 11812 and 11823 = 11817.5 -> 11817. No score
        synthetic_data["11817"] = {}
        
        synthetic_json_path = os.path.join(self.test_dir, "synthetic_golden.json")
        import json
        with open(synthetic_json_path, "w") as f:
            json.dump(synthetic_data, f)
            
        processor = TestWttVideoProcessor(synthetic_json_path)
        video_path = processor.download_video("synthetic", self.test_dir)
        
        finder = MatchStartFinder(
            video_path=video_path,
            output_dir=self.test_dir,
            processor=processor
        )
        
        try:
            matches = finder.find_match_starts()
        finally:
            finder.cleanup()
            
        # Should have found Match 2
        self.assertTrue(len(matches) >= 1)
        # Verify it found Match 2 at either 11818 or 11823 (which is 0:0)
        m = matches[-1]
        self.assertEqual(m.player1, "AN JAEHYUN")
        self.assertEqual(m.player2, "ALEXIS LEBRUN")
        self.assertTrue(11818 <= m.timestamp_seconds <= 11823)



    def test_highlight_reel_filtering(self):
        # Simulate a 15-minute video (900 seconds)
        # 180s intervals: 0, 180, 360, 540, 720, 900
        
        synthetic_data = {}
        
        # 0s to 360s: No score (Simulate a big commercial break > 300s to trigger binary search)
        synthetic_data["0"] = {}
        synthetic_data["180"] = {}
        
        # 360s: Real match starts (REAL PLAYER 1 vs REAL PLAYER 2)
        synthetic_data["360"] = {"player1": "REAL PLAYER 1", "player2": "REAL PLAYER 2", "p1_sets": 0, "p2_sets": 0, "p1_points": 5, "p2_points": 3}
        
        # 540s: Real match continues
        synthetic_data["540"] = {"player1": "REAL PLAYER 1", "player2": "REAL PLAYER 2", "p1_sets": 0, "p2_sets": 0, "p1_points": 8, "p2_points": 9}
        
        # 720s: Real match continues
        synthetic_data["720"] = {"player1": "REAL PLAYER 1", "player2": "REAL PLAYER 2", "p1_sets": 1, "p2_sets": 0, "p1_points": 2, "p2_points": 1}
        
        # 900s: SUDDENLY, A HIGHLIGHT REEL! (Fake player vs Fake player)
        synthetic_data["900"] = {"player1": "FAKE SORA", "player2": "FAKE JANG", "p1_sets": 1, "p2_sets": 3, "p1_points": 10, "p2_points": 8}
        
        # 1080s: Back to the real match
        synthetic_data["1080"] = {"player1": "REAL PLAYER 1", "player2": "REAL PLAYER 2", "p1_sets": 1, "p2_sets": 0, "p1_points": 10, "p2_points": 8}

        # Let's add some binary search steps for the real match around 360s
        synthetic_data["270"] = {}
        synthetic_data["315"] = {"player1": "REAL PLAYER 1", "player2": "REAL PLAYER 2", "p1_sets": 0, "p2_sets": 0, "p1_points": 0, "p2_points": 0}
        
        synthetic_json_path = os.path.join(self.test_dir, "synthetic_golden_highlight.json")
        import json
        with open(synthetic_json_path, "w") as f:
            json.dump(synthetic_data, f)
            
        processor = TestWttVideoProcessor(synthetic_json_path)
        video_path = processor.download_video("synthetic_highlight", self.test_dir)
        
        # We need a duration > 900 for the loop to hit 900
        # Wait, the loop is while timestamp < duration.
        # We can just let the processor say duration is 1000.
        
        finder = MatchStartFinder(
            video_path=video_path,
            output_dir=self.test_dir,
            processor=processor
        )
        
        try:
            matches = finder.find_match_starts()
        finally:
            finder.cleanup()
            
        # The fake highlight (seen only once at 720) should be COMPLETELY ignored.
        # Only the real match should be returned.
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0].player1, "REAL PLAYER 1")
        self.assertEqual(matches[0].player2, "REAL PLAYER 2")
        self.assertEqual(int(matches[0].timestamp_seconds), 315)

if __name__ == '__main__':

    unittest.main()
