import unittest
from ocr_utils import parse_score, is_similar, levenshtein_distance

class TestOcrUtils(unittest.TestCase):

    def test_parse_score_rejects_incomplete_scores(self):
        # Hallucinated or incomplete format fails parsing
        hallucinated_outputs = [
            "Row 1 Line 1: HARIMOTO\nRow 1 Sets: 0\nRow 2 Line 1: HARIIMOTO\nRow 2 Sets: 0",
            "Row 1 Line 1: FELIX\nRow 2 Line 1: LEBRUN",
            "invalid random string"
        ]
        for text in hallucinated_outputs:
            result = parse_score(text)
            self.assertFalse(result.success, f"Expected '{text}' to fail parsing but it succeeded")

    def test_parse_score_accepts_valid_scores(self):
        # Sanity check to ensure valid complete scores are parsed correctly
        valid_text = """Row 1 Line 1: SUN YINGSHA
Row 1 Sets: 2
Row 1 Points: 11
Row 2 Line 1: WANG MANYU
Row 2 Sets: 1
Row 2 Points: 8"""
        result = parse_score(valid_text)
        self.assertTrue(result.success)
        self.assertEqual(result.player1, "SUN YINGSHA")
        self.assertEqual(result.player2, "WANG MANYU")
        self.assertEqual(result.set1, 2)
        self.assertEqual(result.set2, 1)
        self.assertEqual(result.game1, 11)
        self.assertEqual(result.game2, 8)

    def test_parse_score_strips_non_alphabet_artifacts(self):
        # Asserts LaTeX brackets, seed numbers, and symbols are stripped while hyphens/apostrophes are preserved
        text_with_noise = """Row 1 Line 1: NINA MITTELHAM
Row 1 Sets: 0
Row 1 Points: 1
Row 2 Line 1: KUAI MAN {}_4
Row 2 Sets: 0
Row 2 Points: 8"""
        result = parse_score(text_with_noise)
        self.assertTrue(result.success)
        self.assertEqual(result.player1, "NINA MITTELHAM")
        self.assertEqual(result.player2, "KUAI MAN")

        # Hyphenated Korean name and apostrophe surname
        text_hyphen = """Row 1 Line 1: JANG WOO-JIN
Row 1 Sets: 1
Row 1 Points: 5
Row 2 Line 1: D'ARRIGO *
Row 2 Sets: 0
Row 2 Points: 3"""
        res_hyphen = parse_score(text_hyphen)
        self.assertTrue(res_hyphen.success)
        self.assertEqual(res_hyphen.player1, "JANG WOO-JIN")
        self.assertEqual(res_hyphen.player2, "D'ARRIGO")

    def test_levenshtein_distance_correctness(self):
        self.assertEqual(levenshtein_distance("", ""), 0)
        self.assertEqual(levenshtein_distance("A", ""), 1)
        self.assertEqual(levenshtein_distance("A", "A"), 0)
        self.assertEqual(levenshtein_distance("MIMA", "MIWA"), 1)
        self.assertEqual(levenshtein_distance("ALEXIS", "FELIX"), 4)

    def test_is_similar_single_char_ocr_typos(self):
        # Single-character OCR glitches must evaluate to True
        self.assertTrue(is_similar("MIMA HARIMOTO", "MIWA HARIMOTO"), "MIMA vs MIWA Harimoto must be similar")
        self.assertTrue(is_similar("KUAI MAN", "KUAI MEN"), "1-char typo on short name must be similar")
        self.assertTrue(is_similar("SHUNSUKE TOGAMI", "SHUNSUKE TOKAMI"), "G vs K typo must be similar")
        self.assertTrue(is_similar("TRULS MOREGARD", "TRULS MOREGARDH"), "H-dropped typo must be similar")
        self.assertTrue(is_similar("SORA MATSUSHIMA", "SORA MATSUSIMA"), "H-dropped typo must be similar")

    def test_is_similar_separates_different_players_and_relatives(self):
        # Relatives and players with common surnames must evaluate to False
        self.assertFalse(is_similar("FELIX LEBRUN", "ALEXIS LEBRUN"), "Felix vs Alexis Lebrun must NOT be similar")
        self.assertFalse(is_similar("TOMOKAZU HARIMOTO", "MIWA HARIMOTO"), "Tomokazu vs Miwa Harimoto must NOT be similar")
        self.assertFalse(is_similar("MA LONG", "MA LIN"), "Ma Long vs Ma Lin must NOT be similar")
        self.assertFalse(is_similar("WANG MANYU", "WANG YIDI"), "Wang Manyu vs Wang Yidi must NOT be similar")
        self.assertFalse(is_similar("LIN GAOYUAN", "LIN SHIDONG"), "Lin Gaoyuan vs Lin Shidong must NOT be similar")
        self.assertFalse(is_similar("ANTON KALLBERG", "STINA KALLBERG"), "Anton vs Stina Kallberg must NOT be similar")
        self.assertFalse(is_similar("SUN YINGSHA", "CHEN MENG"), "Sun Yingsha vs Chen Meng must NOT be similar")

    def test_is_similar_short_names_guarded(self):
        # Very short 3-letter distinct names must NOT match via distance <= 1
        self.assertFalse(is_similar("LIN", "LIU"), "Short distinct names 'LIN' and 'LIU' must NOT match")
        self.assertFalse(is_similar("CHO", "CHA"), "Short distinct names 'CHO' and 'CHA' must NOT match")

if __name__ == '__main__':
    unittest.main()
