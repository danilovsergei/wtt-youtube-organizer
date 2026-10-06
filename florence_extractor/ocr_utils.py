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
    "DING YLJIE": "DING YAJIE",
    "WATANABE TAKEYEA": "WATANABE / TAKEYA"
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
    trigger_reason: str = ""

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
    
    try:
        # Solution 1: Parse the Optical Step Directly using Regex
        row_1_l1 = re.search(r"Row 1 Line 1:\s*(.+)", generated_text)
        row_1_l2 = re.search(r"Row 1 Line 2:\s*(.+)", generated_text)
        row_1_sets = re.search(r"Row 1 Sets:\s*(\d+)", generated_text)
        row_1_pts = re.search(r"Row 1 Points:\s*(\d+)", generated_text)

        row_2_l1 = re.search(r"Row 2 Line 1:\s*(.+)", generated_text)
        row_2_l2 = re.search(r"Row 2 Line 2:\s*(.+)", generated_text)
        row_2_sets = re.search(r"Row 2 Sets:\s*(\d+)", generated_text)
        row_2_pts = re.search(r"Row 2 Points:\s*(\d+)", generated_text)

        def assemble_name(l1, l2) -> str:
            parts = []
            for line_match in [l1, l2]:
                if not line_match:
                    continue
                cleaned = line_match.group(1).strip()
                if cleaned.lower() in ("none", "n/a", "null", "-", "") or cleaned.isdigit():
                    continue
                parts.append(cleaned)

            combined = " ".join(parts).strip()

            sub_names = combined.split("/")
            cleaned_names = []
            for name in sub_names:
                # 1. Strip leaked score digits
                cleaned = re.sub(r"[\(\[\{]?\b\d+\b[\)\]\}]?", "", name)
                
                # 2. Collapse double 'V' caused by diagonal drop-shadow ghosting
                cleaned = re.sub(r"(?<=[A-Z])VV(?=[A-Z])", "V", cleaned)

                # 3. Safety: collapse any impossible 3+ consecutive identical letters
                cleaned = re.sub(r"([A-Z])\1{2,}", r"\1\1", cleaned)
                
                cleaned_names.append(" ".join(cleaned.split()))

            return " / ".join(cleaned_names).strip()

        p1_name = assemble_name(row_1_l1, row_1_l2)
        p2_name = assemble_name(row_2_l1, row_2_l2)
        
        p1_set = int(row_1_sets.group(1)) if row_1_sets else -1
        p2_set = int(row_2_sets.group(1)) if row_2_sets else -1
        p1_game = int(row_1_pts.group(1)) if row_1_pts else -1
        p2_game = int(row_2_pts.group(1)) if row_2_pts else -1
                
    except Exception as e:
        return ScoreResult(success=False, error=f"Could not parse Regex: '{generated_text}'")
        
    try:
        p1_letters = re.sub(r'[^a-zA-Z]', '', p1_name)
        p2_letters = re.sub(r'[^a-zA-Z]', '', p2_name)
        if len(p1_letters) < 2 or len(p2_letters) < 2:
            return ScoreResult(success=False, error="Invalid player name (insufficient letters)")

        # Reject names containing commas or colons (usually hallucinations or ads)
        if ',' in p1_name or ',' in p2_name or ':' in p1_name or ':' in p2_name:
            return ScoreResult(success=False, error="Invalid player name (contains comma or colon)")

        # Reject common hallucinated ad/graphic words
        invalid_words = {'purple', 'gray', 'grey', 'blue', 'red', 'black', 'white', 'yellow', 'green', 'row', 'and', 'seat', 'live', 'better', 'through', 'sport'}
        
        def has_invalid_word(name):
            words = set(re.findall(r'[a-zA-Z]+', name.lower()))
            return bool(words.intersection(invalid_words))

        if has_invalid_word(p1_name) or has_invalid_word(p2_name):
            return ScoreResult(success=False, error="Invalid player name (hallucinated ad word)")

        set1 = p1_set if p1_set != -1 else 0
        game1 = p1_game
        set2 = p2_set if p2_set != -1 else 0
        game2 = p2_game

        if game1 == -1 or game2 == -1:
            return ScoreResult(success=False, error="Incomplete score digits found")
            
        trigger_reason = ""
        r1_l1_val = row_1_l1.group(1).strip() if row_1_l1 else ""
        r1_l2_val = row_1_l2.group(1).strip() if row_1_l2 else ""
        r2_l1_val = row_2_l1.group(1).strip() if row_2_l1 else ""
        r2_l2_val = row_2_l2.group(1).strip() if row_2_l2 else ""

        def is_valid_line(val: str) -> bool:
            return bool(val) and val.lower() not in ("none", "n/a", "null", "-", "")

        r1_l1_valid = is_valid_line(r1_l1_val)
        r1_l2_valid = is_valid_line(r1_l2_val)
        r2_l1_valid = is_valid_line(r2_l1_val)
        r2_l2_valid = is_valid_line(r2_l2_val)

        # 1. Cross-Row Duplication Gate
        if r1_l2_valid and (r1_l2_val in r2_l1_val or r2_l1_val in r1_l2_val):
            trigger_reason = "cross_row_duplication"

        if not trigger_reason:
            # 2. Doubles Slash Asymmetry Gate
            r1_has_slash = "/" in p1_name
            r2_has_slash = "/" in p2_name
            if r1_has_slash != r2_has_slash:
                trigger_reason = "doubles_slash_asymmetry"
            else:
                # 3. Line-Count Asymmetry Gate
                if r1_l2_valid != r2_l2_valid and not (r1_has_slash and r2_has_slash):
                    trigger_reason = "line_count_asymmetry"

        if not trigger_reason:
            # 4. Multi-Target Optical Stutter Gate (Evaluates ALL duplicate letters using findall)
            stutter_chars = []
            for name in (p1_name, p2_name):
                all_dupes = set(re.findall(r"([A-Z])\1", name))
                for char in all_dupes:
                    stutter_chars.append(char)
            if stutter_chars:
                # Join all stutter chars so the Foveation pass can verify ALL of them!
                trigger_reason = "optical_stutter_" + "".join(stutter_chars)

        return ScoreResult(
            success=True,
            player1=p1_name,
            set1=set1,
            game1=game1,
            player2=p2_name,
            set2=set2,
            game2=game2,
            trigger_reason=trigger_reason
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

import cv2
import numpy as np

def classify_6_vs_8(digit_crop_bgr: np.ndarray) -> int:
    """Classifies 6 vs 8 in <1ms by checking if the top-right loop is physically open."""
    gray = cv2.cvtColor(digit_crop_bgr, cv2.COLOR_BGR2GRAY)

    _, thresh = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    coords = cv2.findNonZero(thresh)
    if coords is None:
        return 0
    x, y, w, h = cv2.boundingRect(coords)
    digit = thresh[y : y + h, x : x + w]

    mid_y = h // 2
    top_half = digit[0:mid_y, :]

    col_cutoff = int(w * 0.7)
    top_right_density = np.mean(top_half[:, col_cutoff:] == 255)

    if top_right_density < 0.25:
        return 6
    return 8

def crop_normalized_box(image, box: list[int], pad: int = 2) -> np.ndarray:
    """Converts [ymin, xmin, ymax, xmax] (0-1000) into an exact numpy BGR pixel crop."""
    w, h = image.size
    ymin, xmin, ymax, xmax = box

    y1 = max(0, int((ymin / 1000.0) * h) - pad)
    x1 = max(0, int((xmin / 1000.0) * w) - pad)
    y2 = min(h, int((ymax / 1000.0) * h) + pad)
    x2 = min(w, int((xmax / 1000.0) * w) + pad)

    img_np = np.array(image)
    crop_rgb = img_np[y1:y2, x1:x2]
    return cv2.cvtColor(crop_rgb, cv2.COLOR_RGB2BGR)

def process_and_verify_scoreboard(image, raw_qwen_json: dict) -> dict:
    """Pipes Qwen's grounded coordinate crops to the micro-classifier when scores are 6 or 8."""
    data = raw_qwen_json

    for row in ("row_1", "row_2"):
        pts_key = f"{row}_points"
        box_key = f"{row}_points_box"

        if data.get(pts_key) in (6, 8) and box_key in data:
            box = data[box_key]
            if isinstance(box, list) and len(box) == 4:
                digit_crop = crop_normalized_box(image, box)
                corrected_digit = classify_6_vs_8(digit_crop)
                data[pts_key] = corrected_digit

        data.pop(box_key, None)

    return data
