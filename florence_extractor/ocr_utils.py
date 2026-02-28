import re
import difflib
from dataclasses import dataclass

# Max points to consider as "early match" - covers most of first game
MAX_EARLY_GAME_POINTS = 15

@dataclass
class ScoreResult:
    """Represents the result of score extraction from a frame."""
    success: bool
    player1: str = ""
    player2: str = ""
    set1: int = -1
    set2: int = -1
    game1: int = -1
    game2: int = -1
    error: str = ""

    def is_match_start(self) -> bool:
        """Check if this is a match start (0:0 sets, 0:0 game)."""
        return (self.success and
                self.set1 == 0 and self.set2 == 0 and
                self.game1 == 0 and self.game2 == 0)

    def is_game_start(self) -> bool:
        """Check if this is a game start (0:0 game, any set score)."""
        return self.success and self.game1 == 0 and self.game2 == 0

    def is_early_match(self) -> bool:
        """Check if this is early in the first game (sets 0:0, few points)."""
        if not self.success:
            return False
        # Sets must be 0:0 (first game of match)
        if self.set1 != 0 or self.set2 != 0:
            return False
        # Total points must be low (1:0, 0:1, 2:0, 0:2, 1:1, 2:1, etc)
        return self.total_points() <= MAX_EARLY_GAME_POINTS

    def total_points(self) -> int:
        """Return total points in current game."""
        if not self.success:
            return -1
        return self.game1 + self.game2

def parse_score(generated_text: str) -> ScoreResult:
    """
    Parse Florence-2 output to extract score data into a ScoreResult object.
    """
    # Very robust regex that allows spacing/punctuation hallucinations 
    # between numbers, and makes the game score fully optional in case of early generation stop.
    pattern = (
        r"row 1:\s*(.*?),\s*(\d+)(?:.*?(\d+))?\s*"
        r"row 2:\s*(.*?),\s*(\d+)(?:.*?(\d+))?$"
    )
    match = re.search(pattern, generated_text.strip())

    if match:
        try:
            # the shared regex handles empty game score as "", so default it to -1 if we can't parse
            set1_str = match.group(2).strip()
            game1_str = match.group(3).strip() if match.group(3) else ""
            
            set2_str = match.group(5).strip()
            game2_str = match.group(6).strip() if match.group(6) else ""

            set1 = int(set1_str) if set1_str else 0
            game1 = int(game1_str) if game1_str else -1
            set2 = int(set2_str) if set2_str else 0
            game2 = int(game2_str) if game2_str else -1

            return ScoreResult(
                success=True,
                player1=match.group(1).strip(),
                set1=set1,
                game1=game1,
                player2=match.group(4).strip(),
                set2=set2,
                game2=game2
            )
        except ValueError as e:
            return ScoreResult(success=False, error=f"Score parse error: {e}")

    return ScoreResult(success=False, error=f"Could not parse: '{generated_text}'")

def normalize_text(text):
    """Normalize text for comparison by keeping only uppercase alphanumerics."""
    return re.sub(r'[^A-Z0-9]', '', str(text).upper())

def is_similar(str1, str2, threshold=0.92):
    """Check if two strings are highly similar using difflib to handle slight OCR drops."""
    norm1 = normalize_text(str1)
    norm2 = normalize_text(str2)
    
    if norm1 == norm2:
        return True
    
    # Allow 1-2 character drops in long names
    ratio = difflib.SequenceMatcher(None, norm1, norm2).ratio()
    return ratio >= threshold