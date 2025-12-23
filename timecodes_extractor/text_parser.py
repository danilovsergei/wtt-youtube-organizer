import easyocr
import cv2
import sys
import numpy as np


def analyze_scoreboard_smart(image_path):
    print(f"--- Loading image: {image_path} ---")
    img = cv2.imread(image_path)
    if img is None:
        return

    h, w, _ = img.shape

    # 1. ROI: Bottom Left
    y_start = int(h * 0.85)
    # for some reason making x area larger helps with detecting game score
    # for the first row
    x_end = int(w * 0.50)
    roi = img[y_start:h, 0:x_end]

    # 2. ZOOM: 3x Upscale
    scale = 3
    roi_zoomed = cv2.resize(roi, None, fx=scale, fy=scale,
                            interpolation=cv2.INTER_CUBIC)

    # 3. GRAYSCALE & INVERT
    roi_gray = cv2.cvtColor(roi_zoomed, cv2.COLOR_BGR2GRAY)
    roi_inverted = cv2.bitwise_not(roi_gray)

    # 4. PRE-PROCESSING
    # Strategy: Run OCR on TWO versions of the image and merge results.
    # 1. Inverted (Good for Names and high contrast numbers)
    # 2. Adaptive Threshold (Good for low contrast numbers like Sets on Orange)

    roi_list = []
    roi_list.append(roi_inverted)

    # Adaptive Threshold (Black text on White bg)
    roi_adaptive = cv2.adaptiveThreshold(roi_gray, 255,
                                         cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                         cv2.THRESH_BINARY_INV, 11, 2)
    roi_list.append(roi_adaptive)

    # Save debug views
    cv2.imwrite("debug_ai_view.jpg", roi_inverted)
    cv2.imwrite("debug_ai_adaptive.jpg", roi_adaptive)

    roi_processed = roi_inverted

    # 5. INITIAL DETECTION
    reader = easyocr.Reader(['en'], gpu=False)
    full_whitelist = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ. '

    all_results = []
    for processed_img in roi_list:
        res = reader.readtext(processed_img, allowlist=full_whitelist)
        all_results.extend(res)

    # MERGE RESULTS (Remove duplicates based on overlap)
    # Prefer earlier results (Inverted)
    unique_results = []

    def get_bbox_rect(bbox):
        tl = bbox[0]
        br = bbox[2]
        return int(tl[0]), int(tl[1]), int(br[0]), int(br[1])

    def compute_iou(boxA, boxB):
        # determine the (x, y)-coordinates of the intersection rectangle
        xA = max(boxA[0], boxB[0])
        yA = max(boxA[1], boxB[1])
        xB = min(boxA[2], boxB[2])
        yB = min(boxA[3], boxB[3])
        interArea = max(0, xB - xA) * max(0, yB - yA)
        boxAArea = (boxA[2] - boxA[0]) * (boxA[3] - boxA[1])
        boxBArea = (boxB[2] - boxB[0]) * (boxB[3] - boxB[1])
        # Return intersection over minimum area (to catch containment)
        minArea = min(boxAArea, boxBArea)
        if minArea == 0:
            return 0
        return interArea / float(minArea)

    for item in all_results:
        bbox, text, prob = item
        box = get_bbox_rect(bbox)

        # Filter noise by width ONLY for score columns (right side)
        # Names are wide, so we keep them.
        w_box = box[2] - box[0]
        cx = (box[0] + box[2]) // 2
        roi_w = roi_inverted.shape[1]

        if cx > (roi_w * 0.5):
            # Score column: Should be small digits
            if w_box > 100:
                continue

        is_duplicate = False
        for existing in unique_results:
            ex_box = get_bbox_rect(existing[0])
            iou = compute_iou(box, ex_box)
            if iou > 0.5:
                is_duplicate = True
                break

        if not is_duplicate:
            unique_results.append(item)

    results = unique_results

    found_items = []
    roi_h, roi_w = roi_inverted.shape

    print("\n--- Processing Items ---")

    for (bbox, text, prob) in results:
        top_left = bbox[0]
        bottom_right = bbox[2]
        cy = int((top_left[1] + bottom_right[1]) / 2)
        cx = int((top_left[0] + bottom_right[0]) / 2)
        w_box = int(bottom_right[0] - top_left[0])

        # --- THE SMART RE-CHECK ---
        # If the text is on the RIGHT SIDE ( > 50% width), it MUST be a score.
        # If it contains letters (like "LUD"), re-read it as a number.
        is_score_column = cx > (roi_w * 0.5)
        is_not_digit = not text.replace('.', '').isdigit()

        if is_score_column and is_not_digit:
            print(f"   -> Fixing suspicious score: '{text}' at x={cx}")

            # 1. Crop just this specific number box
            # Add padding to help OCR context
            pad = 5
            y_min = max(0, int(top_left[1]) - pad)
            y_max = min(roi_h, int(bottom_right[1]) + pad)
            x_min = max(0, int(top_left[0]) - pad)
            x_max = min(roi_w, int(bottom_right[0]) + pad)

            number_crop = roi_processed[y_min:y_max, x_min:x_max]

            # 2. Re-run OCR with STRICT number-only allowlist
            number_results = reader.readtext(
                number_crop, allowlist='0123456789')

            if number_results:
                # Take the first result
                new_text = number_results[0][1]
                prob = number_results[0][2]
                print(
                    f"      Changed '{text}' to '{new_text}' (conf: {prob:.2f})")
                text = new_text
            else:
                pass

        # Cleanup names (remove trailing dots/spaces)
        if not is_score_column:
            text = text.strip(' .')

        found_items.append({'text': text, 'y': cy, 'x': cx})

    # 6. Grouping Logic
    found_items.sort(key=lambda k: k['y'])
    rows = []
    row_tolerance = 20 * scale

    if found_items:
        current_row = [found_items[0]]
        for item in found_items[1:]:
            prev_item = current_row[-1]
            if abs(item['y'] - prev_item['y']) < row_tolerance:
                current_row.append(item)
            else:
                rows.append(current_row)
                current_row = [item]
        rows.append(current_row)

    # 7. Print Results
    print("\n--- FINAL RESULTS ---")
    for i, row in enumerate(rows):
        row.sort(key=lambda k: k['x'])
        parts = [item['text'] for item in row]
        print(f"Row {i+1}: {'  |  '.join(parts)}")


if __name__ == "__main__":
    path = '/home/sdanilov/Build/wtt-youtube-organizer/videos/clip-3000.0-0.001.jpg'
    analyze_scoreboard_smart(path)
