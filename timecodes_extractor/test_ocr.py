import csv
import sys
import argparse
import os
from concurrent.futures import ProcessPoolExecutor, as_completed

# Ensure we can import the module if running as script
sys.path.append(os.getcwd())

try:
    from timecodes_extractor.text_parser import analyze_scoreboard_smart
except ImportError:
    try:
        from text_parser import analyze_scoreboard_smart
    except ImportError:
        print("Error: Could not import analyze_scoreboard_smart from timecodes_extractor.text_parser")
        sys.exit(1)


def process_row(row_data):
    """
    Process a single row from the CSV.
    row_data: list corresponding to columns.
    Expected columns:
    0: Image Path
    1: Row 1 Player
    2: Row 2 Player
    3: Row 1 Set Score
    4: Row 2 Set Score
    5: Row 1 Game Score
    6: Row 2 Game Score
    """
    # Ensure row has enough columns
    if len(row_data) < 7:
        return {
            "image": row_data[0] if row_data else "Unknown",
            "passed": False,
            "errors": [f"Insufficient columns in CSV. Expected 7, got {len(row_data)}"]
        }

    image_path = row_data[0].strip()
    exp_p1 = row_data[1].strip()
    exp_p2 = row_data[2].strip()
    exp_s1 = row_data[3].strip()
    exp_s2 = row_data[4].strip()
    exp_g1 = row_data[5].strip()
    exp_g2 = row_data[6].strip()

    result = {
        "image": image_path,
        "passed": False,
        "errors": [],
        "ocr_data": []
    }

    if not os.path.exists(image_path):
        result["errors"].append(f"Image file not found: {image_path}")
        return result

    try:
        # Run OCR
        ocr_rows = analyze_scoreboard_smart(image_path, debug=False)

        if not ocr_rows:
            result["errors"].append("No data returned from OCR")
            return result

        result["ocr_data"] = ocr_rows

        # Validation Logic
        # We expect 2 rows of data from OCR
        if len(ocr_rows) < 2:
            result["errors"].append(
                f"Expected 2 rows from OCR, got {len(ocr_rows)}")

        # Helper to safely get index
        def get_col(r, idx):
            return r[idx].strip() if idx < len(r) else ""

        # Compare Row 1
        # OCR output structure: [Player, SetScore, GameScore] (Sorted by X)
        if len(ocr_rows) > 0:
            row1 = ocr_rows[0]
            act_p1 = get_col(row1, 0)
            act_s1 = get_col(row1, 1)
            act_g1 = get_col(row1, 2)

            if act_p1 != exp_p1:
                result["errors"].append(
                    f"Row 1 Player: expected '{exp_p1}', got '{act_p1}'")
            if act_s1 != exp_s1:
                result["errors"].append(
                    f"Row 1 Set Score: expected '{exp_s1}', got '{act_s1}'")
            if act_g1 != exp_g1:
                result["errors"].append(
                    f"Row 1 Game Score: expected '{exp_g1}', got '{act_g1}'")

        # Compare Row 2
        if len(ocr_rows) > 1:
            row2 = ocr_rows[1]
            act_p2 = get_col(row2, 0)
            act_s2 = get_col(row2, 1)
            act_g2 = get_col(row2, 2)

            if act_p2 != exp_p2:
                result["errors"].append(
                    f"Row 2 Player: expected '{exp_p2}', got '{act_p2}'")
            if act_s2 != exp_s2:
                result["errors"].append(
                    f"Row 2 Set Score: expected '{exp_s2}', got '{act_s2}'")
            if act_g2 != exp_g2:
                result["errors"].append(
                    f"Row 2 Game Score: expected '{exp_g2}', got '{act_g2}'")

        if not result["errors"]:
            result["passed"] = True

    except Exception as e:
        result["errors"].append(f"Exception during OCR processing: {str(e)}")

    return result


def main():
    parser = argparse.ArgumentParser(description="Test OCR against CSV data")
    parser.add_argument("csv_file", help="Path to CSV file with expected data")
    args = parser.parse_args()

    if not os.path.exists(args.csv_file):
        print(f"Error: CSV file not found: {args.csv_file}")
        return

    rows = []
    try:
        with open(args.csv_file, 'r') as f:
            reader = csv.reader(f)
            all_rows = list(reader)
            if not all_rows:
                print("Empty CSV file")
                return

            # Check header
            start_idx = 0
            if "image path" in all_rows[0][0].lower():
                start_idx = 1

            rows = all_rows[start_idx:]

            # Filter empty rows
            rows = [r for r in rows if any(r)]

    except Exception as e:
        print(f"Error reading CSV: {e}")
        return

    print(f"Processing {len(rows)} images...")

    results = []
    # Run sequentially to avoid multiprocess issues with EasyOCR/Torch
    for row in rows:
        res = process_row(row)
        results.append(res)

        status = "PASSED" if res["passed"] else "FAILED"
        print(f"Image: {res['image']} - {status}")
        if not res["passed"]:
            if res.get("ocr_data"):
                print("--- FINAL RESULTS ---")
                for i, r in enumerate(res["ocr_data"]):
                    print(f"Row {i+1}: {'  |  '.join(r)}")

            for err in res["errors"]:
                print(f"  - {err}")
        print("-" * 40)

    print("\n--- Final Summary ---")
    passed = sum(1 for r in results if r["passed"])
    failed = len(results) - passed
    print(f"Total: {len(results)}, Passed: {passed}, Failed: {failed}")

    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
