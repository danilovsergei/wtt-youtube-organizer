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
    import re
    
    # Split the generated text into row 1 and row 2 blocks
    row1_match = re.search(r"row 1:\s*(.*?)(?:\s*row 2|$)", generated_text)
    row2_match = re.search(r"row 2:\s*(.*?)$", generated_text)
    
    if not row1_match or not row2_match:
        return ScoreResult(success=False, error=f"Could not parse rows: '{generated_text}'")
        
    def parse_row(row_text):
        # We know names can have numbers (e.g. "LEE SEUNG500") and Florence sometimes drops commas.
        # But usually there is a comma separating the name from the scores: "LEE SEUNG500, 0, 4"
        # Let's try to find the LAST comma first.
        
        # Actually, let's use regex to find the name (anything), then an optional comma, then 1-3 numbers at the end.
        match = re.search(r'^(.*?)(?:,\s*|\s+)(\d+(?:[^\d]*\d+)*)$', row_text.strip())
        
        if match:
            name = match.group(1).strip().rstrip(",")
            numbers_str = match.group(2)
            numbers = re.findall(r'\d+', numbers_str)
        else:
            # Fallback if no clear separation
            numbers = re.findall(r'\d+', row_text)
            if not numbers:
                return row_text.strip(), "", ""
            name = row_text[:row_text.rfind(numbers[0])].strip().rstrip(",")
            
        if not numbers:
            return name, "", ""
        elif len(numbers) == 1:
            return name, numbers[0], ""
        else:
            return name, numbers[0], numbers[-1]
            
    try:
        p1_name, p1_set, p1_game = parse_row(row1_match.group(1))
        p2_name, p2_set, p2_game = parse_row(row2_match.group(1))
        
        set1 = int(p1_set) if p1_set else 0
        game1 = int(p1_game) if p1_game else -1
        set2 = int(p2_set) if p2_set else 0
        game2 = int(p2_game) if p2_game else -1
        
        return ScoreResult(
            success=True,
            player1=p1_name,
            set1=set1,
            game1=game1,
            player2=p2_name,
            set2=set2,
            game2=game2
        )
    except Exception as e:
        return ScoreResult(success=False, error=f"Score parse error: {e}")

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