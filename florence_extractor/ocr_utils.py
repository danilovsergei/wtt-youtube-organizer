import re
import difflib
from dataclasses import dataclass

MAX_EARLY_GAME_POINTS = 15

# Strict, non-fuzzy mapping of known WTT font tokenizer hallucinations to their correct canonical names
KNOWN_OCR_ALIASES = {
    "DIMITROV DIMITTAR": "DIMITROV DIMITAR",
    "DIMITROV DIMMITAR": "DIMITROV DIMITAR",
    "DIMITROV DIMIMITAR": "DIMITROV DIMITAR",
    "CHUDZICKI MAKSyM": "CHUDZICKI MAKSYM",
    "DING YLJIE": "DING YAJIE"
}


@dataclass
class ScoreResult:
    success: bool
    player1: str = ""
    player2: str = ""
    set1: int = -1
    set2: int = -1
    game1: int = -1
    game2: int = -1
    error: str = ""

    def is_match_start(self) -> bool:
        return (self.success and
                self.set1 == 0 and self.set2 == 0 and
                self.game1 == 0 and self.game2 == 0)

    def is_game_start(self) -> bool:
        return self.success and self.game1 == 0 and self.game2 == 0

    def is_early_match(self) -> bool:
        if not self.success:
            return False
        if self.set1 != 0 or self.set2 != 0:
            return False
        return self.total_points() <= MAX_EARLY_GAME_POINTS

    def total_points(self) -> int:
        if not self.success:
            return -1
        return self.game1 + self.game2


def parse_score(generated_text: str) -> ScoreResult:
    import re
    row1_match = re.search(r"row 1:\s*(.*?)(?:\s*row 2|$)", generated_text)
    row2_match = re.search(r"row 2:\s*(.*?)$", generated_text)

    if not row1_match or not row2_match:
        return ScoreResult(success=False, error=f"Could not parse rows: '{generated_text}'")

    def parse_row(row_text):
        match = re.search(
            r'^(.*?)(?:[,\.]\s*|\s+)(\d+(?:[^\d]*\d+)*)$', row_text.strip())
        if match:
            name = match.group(1).strip().rstrip(",.")
            numbers_str = match.group(2)
            numbers = re.findall(r'\d+', numbers_str)
        else:
            numbers = re.findall(r'\d+', row_text)
            if not numbers:
                return row_text.strip(), "", ""
            name = row_text[:row_text.rfind(numbers[0])].strip().rstrip(",.")

        if not numbers:
            return name, "", ""
        elif len(numbers) == 1:
            return name, numbers[0], ""
        else:
            return name, numbers[0], numbers[-1]

    try:
        p1_name, p1_set, p1_game = parse_row(row1_match.group(1))
        p2_name, p2_set, p2_game = parse_row(row2_match.group(1))

        # Apply known deterministic tokenizer alias corrections
        # p1_name = KNOWN_OCR_ALIASES.get(p1_name, p1_name)
        # p2_name = KNOWN_OCR_ALIASES.get(p2_name, p2_name)

        set1 = int(p1_set) if p1_set else 0
        game1 = int(p1_game) if p1_game else -1
        set2 = int(p2_set) if p2_set else 0
        game2 = int(p2_game) if p2_game else -1

        if game1 == -1 or game2 == -1:
            return ScoreResult(success=False, error="Incomplete score digits found")

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
    return re.sub(r'[^A-Z0-9]', '', str(text).upper())


def is_similar(str1, str2, threshold=0.92):
    norm1 = normalize_text(str1)
    norm2 = normalize_text(str2)
    if norm1 == norm2:
        return True
    ratio = difflib.SequenceMatcher(None, norm1, norm2).ratio()
    return ratio >= threshold
