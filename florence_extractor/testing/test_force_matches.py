import sys
import os
import json
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from test_video_processor import TestWttVideoProcessor
from match_start_finder import MatchStartFinder
from ocr_utils import is_similar

class TestForceMatchesDynamicOffset(unittest.TestCase):
    def setUp(self):
        self.mock_json_path = "/tmp/mock_golden.json"
        
        # Create a mock video JSON where:
        # Match 1: PLAYER A vs PLAYER B (starts at 30 seconds)
        # Match 2: PLAYER C vs PLAYER D (starts at 3600 seconds)
        mock_data = {
            "30": {"player1": "PLAYER A", "player2": "PLAYER B", "p1_sets": 0, "p2_sets": 0, "p1_points": 0, "p2_points": 0},
            "60": {"player1": "PLAYER A", "player2": "PLAYER B", "p1_sets": 0, "p2_sets": 0, "p1_points": 1, "p2_points": 0},
            "3600": {"player1": "PLAYER C", "player2": "PLAYER D", "p1_sets": 0, "p2_sets": 0, "p1_points": 0, "p2_points": 0},
            "3660": {"player1": "PLAYER C", "player2": "PLAYER D", "p1_sets": 0, "p2_sets": 0, "p1_points": 1, "p2_points": 0},
        }
        with open(self.mock_json_path, "w") as f:
            json.dump(mock_data, f)
            
        self.processor = TestWttVideoProcessor(self.mock_json_path)

    def tearDown(self):
        if os.path.exists(self.mock_json_path):
            os.remove(self.mock_json_path)

    def test_dynamic_offset_resolution(self):
        # Simulate what mine_new_players.py does for `--force_matches VID:PLAYER_C`
        target_player = "PLAYER C"
        
        finder = MatchStartFinder(video_path="/tmp/fake_video.mp4", output_dir="/tmp/", processor=self.processor)
        matches = finder.find_match_starts()
        
        resolved_offset = None
        for m in matches:
            if is_similar(target_player, m.player1) or is_similar(target_player, m.player2):
                resolved_offset = int(m.timestamp_seconds)
                break
                
        # It should correctly bypass Match 1 (at 30s) and find Match 2 (at 3600s)
        self.assertIsNotNone(resolved_offset, "Should have found the match offset dynamically")
        self.assertEqual(resolved_offset, 3600, "Should have resolved to the exact start of Match 2")

if __name__ == '__main__':
    unittest.main()

