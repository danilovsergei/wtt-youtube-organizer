import easyocr
import cv2
import sys
import numpy as np

# Initialize Reader globally to avoid reloading model for every image
reader = easyocr.Reader(['en'], gpu=False)


def analyze_scoreboard_smart(image_path, debug=True):
    if debug:
        print(f"--- Loading image: {image_path} ---")
    img = cv2.imread(image_path)
    if img is None:
        return

    h, w, _ = img.shape

    # 1. ROI: Bottom Left
    y_start = int(h * 0.85)
    # for some reason making x area larger helps with detecting game score
    # for the first row
    x_end = int(w * 0.65)
    roi = img[y_start:h, 0:x_end]

    # 2. ZOOM: 3x Upscale
    scale = 4
    roi_zoomed = cv2.resize(roi, None, fx=scale, fy=scale,
                            interpolation=cv2.INTER_CUBIC)

    # 3. GRAYSCALE & INVERT
    roi_gray = cv2.cvtColor(roi_zoomed, cv2.COLOR_BGR2GRAY)

    # Create Equalized Gray for Recovery
    roi_gray_eq = cv2.equalizeHist(roi_gray)

    # Precompute High Sensitivity Adaptive Thresholds GLOBALLY
    # C = -8 (Good for Img 1, 3)
    roi_adaptive_high_1 = cv2.adaptiveThreshold(roi_gray_eq, 255,
                                                cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                                cv2.THRESH_BINARY_INV, 11, -8)
    # C = -20 (Good for Img 2)
    roi_adaptive_high_2 = cv2.adaptiveThreshold(roi_gray_eq, 255,
                                                cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                                cv2.THRESH_BINARY_INV, 11, -20)
    # C = -12 (Intermediate)
    roi_adaptive_high_3 = cv2.adaptiveThreshold(roi_gray_eq, 255,
                                                cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                                cv2.THRESH_BINARY_INV, 11, -12)

    # C = 2 (Standard)
    roi_adaptive_high_4 = cv2.adaptiveThreshold(roi_gray_eq, 255,
                                                cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                                cv2.THRESH_BINARY_INV, 11, 2)
    # C = -4 (Light)
    roi_adaptive_high_5 = cv2.adaptiveThreshold(roi_gray_eq, 255,
                                                cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                                cv2.THRESH_BINARY_INV, 11, -4)

    roi_inverted = cv2.bitwise_not(roi_gray)

    # 4. PRE-PROCESSING
    # Strategy: Run OCR on TWO versions of the image and merge results.
    # 1. Inverted (Good for Names and high contrast numbers)
    # 2. Adaptive Threshold (Good for low contrast numbers like Sets on Orange)

    roi_list = []
    roi_list.append(roi_inverted)

    # Standard Adaptive Threshold (Black text on White bg)
    roi_adaptive = cv2.adaptiveThreshold(roi_gray, 255,
                                         cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                         cv2.THRESH_BINARY_INV, 11, 2)
    roi_list.append(roi_adaptive)

    # Save debug views
    cv2.imwrite("debug_ai_view.jpg", roi_inverted)
    cv2.imwrite("debug_ai_adaptive.jpg", roi_adaptive)

    roi_processed = roi_inverted

    # 5. INITIAL DETECTION
    # reader = easyocr.Reader(['en'], gpu=False) # MOVED TO GLOBAL
    full_whitelist = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ. '

    all_results = []
    for processed_img in roi_list:
        # width_ths=0.2 helps prevent merging Name and Set Score
        res = reader.readtext(
            processed_img, allowlist=full_whitelist, width_ths=0.2)
        all_results.extend(res)

    # MERGE RESULTS (Remove duplicates based on overlap)
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
            if iou > 0.2:
                is_duplicate = True
                break

            # Check for Same Text + Proximity (handle shifted duplicates)
            ex_text = existing[1]
            if text == ex_text:
                cx1 = (box[0] + box[2]) / 2
                cy1 = (box[1] + box[3]) / 2
                cx2 = (ex_box[0] + ex_box[2]) / 2
                cy2 = (ex_box[1] + ex_box[3]) / 2
                dist = ((cx1 - cx2)**2 + (cy1 - cy2)**2)**0.5
                if dist < 50:  # 50 pixels tolerance
                    is_duplicate = True
                    break

        if not is_duplicate:
            unique_results.append(item)

    results = unique_results

    found_items = []
    roi_h, roi_w = roi_inverted.shape

    if debug:
        print("\n--- Processing Items ---")

    for (bbox, text, prob) in results:
        top_left = bbox[0]
        bottom_right = bbox[2]
        if debug:
            print(f"   Item: '{text}' at {top_left}")
        cy = int((top_left[1] + bottom_right[1]) / 2)
        cx = int((top_left[0] + bottom_right[0]) / 2)
        w_box = int(bottom_right[0] - top_left[0])

        # --- THE SMART RE-CHECK ---
        is_score_column = cx > (roi_w * 0.5)
        is_not_digit = not text.replace('.', '').isdigit()

        if is_score_column and is_not_digit:
            if debug:
                print(f"   -> Fixing suspicious score: '{text}' at x={cx}")

            # 1. Crop just this specific number box
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
                new_text = number_results[0][1]
                if debug:
                    print(
                        f"      Changed '{text}' to '{new_text}' (conf: {prob:.2f})")
                text = new_text
            else:
                pass

        # Cleanup names (remove trailing dots/spaces)
        if not is_score_column:
            text = text.strip(' .')

        # Keep box info for recovery
        rect = get_bbox_rect(bbox)  # x1, y1, x2, y2
        found_items.append({'text': text, 'y': cy, 'x': cx, 'rect': rect})

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
    if debug:
        print("\n--- FINAL RESULTS ---")
    structured_result = []

    def is_digit(s):
        return s.replace('.', '').strip().isdigit()

    for i, row in enumerate(rows):
        row.sort(key=lambda k: k['x'])

        items = [item['text'] for item in row]

        # New "Global Digit Logic" Parsing
        digits = []
        for idx, item in enumerate(items):
            if is_digit(item):
                digits.append((idx, item))

        game_score = ""
        set_score = ""
        name_end_idx = len(items)

        # Keep track of objects for recovery
        game_item = None
        set_item = None

        valid_pairs = []

        if len(digits) >= 2:
            # Iterate through adjacent pairs
            for k in range(len(digits) - 1):
                idx_set, val_set = digits[k]
                idx_game, val_game = digits[k+1]

                # Proximity check: x distance between set and game score
                x_set = row[idx_set]['x']
                x_game = row[idx_game]['x']
                gap = x_game - x_set

                # Gap threshold tuned for scale=3
                if int(val_set) <= 19 and gap < 150:
                    valid_pairs.append({
                        'set': val_set, 'game': val_game,
                        'idx_set': idx_set, 'idx_game': idx_game,
                        'k': k
                    })

        selected_pair = None
        if len(valid_pairs) == 1:
            selected_pair = valid_pairs[0]
        elif len(valid_pairs) > 1:
            # Conflict resolution
            best_p = valid_pairs[-1]
            for p in reversed(valid_pairs[:-1]):
                if best_p['set'] == best_p['game']:
                    best_p = p
                else:
                    break
            selected_pair = best_p

        if selected_pair:
            set_score = selected_pair['set']
            game_score = selected_pair['game']
            name_end_idx = selected_pair['idx_set']
            set_item = row[selected_pair['idx_set']]
            game_item = row[selected_pair['idx_game']]

        elif len(digits) == 1:
            # Only one digit. Assume Game Score.
            idx_game, val_game = digits[0]
            game_score = val_game
            name_end_idx = idx_game
            game_item = row[idx_game]

        elif len(digits) >= 2:
            # Fallback for when proximity check fails but we have digits.
            # Assume last digit is Game Score.
            idx_game, val_game = digits[-1]
            game_score = val_game
            # Name ends before game score? No, before FIRST digit usually.
            name_end_idx = idx_game
            # But if we don't know which is set score, maybe name ends before first digit in `digits`?
            name_end_idx = digits[0][0]
            game_item = row[idx_game]
            # Leave set_score empty to trigger recovery

        name_items = row[:name_end_idx]
        name = " ".join([item['text'] for item in name_items])

        # Clean digits from name
        name = name.strip('0123456789 .Il')

        # FIX FOR IMAGE 2: Check if Name ends with digit (before strip), move to Set Score
        # (This is handled by digit logic mostly, but if split failed)

        # Recovery Logic for Set Score
        should_recover = False
        if not set_score and name_items and game_item:
            should_recover = True
        # elif set_score == '2' and name_items and game_item:
        #    should_recover = True
        elif set_score == '4' and name_items and game_item:  # Check for 4->1 error
            should_recover = True
        elif set_score and int(set_score) > 4 and name_items and game_item:
            should_recover = True

        if should_recover:
            if debug:
                print("Attempting to recover Set Score...")

            name_x_max = max([it['rect'][2] for it in name_items])
            game_x_min = game_item['rect'][0]

            y_min = min(min([it['rect'][1]
                        for it in name_items]), game_item['rect'][1])
            y_max = max(max([it['rect'][3]
                        for it in name_items]), game_item['rect'][3])

            pad = 50  # Pad 50 found via tuning
            x_start = name_x_max - pad
            x_end_rec = game_x_min + pad

            if x_end_rec > x_start:
                # Helper for OCR on crop
                def run_ocr_on_crop(roi_crop):
                    if roi_crop.size == 0:
                        return None
                    # Allow 'I' and 'l' in recovery to catch '1' misreads
                    rec_res = reader.readtext(
                        roi_crop, allowlist='0123456789Il', width_ths=0.2, text_threshold=0.4)
                    if rec_res:
                        # Find best candidate: Closest to center of crop
                        crop_w = x_end_rec - x_start
                        center_x = crop_w / 2
                        best_dist = float('inf')
                        best_digit = None
                        for (bbox, text, prob) in rec_res:
                            item_cx = (bbox[0][0] + bbox[1][0]) / 2
                            dist = abs(item_cx - center_x)

                            # Map I/l to 1
                            text = text.replace('I', '1').replace('l', '1')

                            if text.isdigit():
                                if dist < best_dist:
                                    best_dist = dist
                                    best_digit = text
                        return best_digit.strip() if best_digit else None
                    return None

                # Multi-Pass Recovery
                roi_rec_crop_1 = roi_adaptive_high_1[y_min:y_max,
                                                     x_start:x_end_rec]
                res_1 = run_ocr_on_crop(roi_rec_crop_1)

                roi_rec_crop_2 = roi_adaptive_high_2[y_min:y_max,
                                                     x_start:x_end_rec]
                res_2 = run_ocr_on_crop(roi_rec_crop_2)

                roi_rec_crop_3 = roi_adaptive_high_3[y_min:y_max,
                                                     x_start:x_end_rec]
                res_3 = run_ocr_on_crop(roi_rec_crop_3)

                roi_rec_crop_4 = roi_adaptive_high_4[y_min:y_max,
                                                     x_start:x_end_rec]
                res_4 = run_ocr_on_crop(roi_rec_crop_4)

                roi_rec_crop_5 = roi_adaptive_high_5[y_min:y_max,
                                                     x_start:x_end_rec]
                res_5 = run_ocr_on_crop(roi_rec_crop_5)

                roi_rec_crop_6 = roi_adaptive_high_1[y_min:y_max,
                                                     x_start:x_end_rec]
                # Re-using roi_adaptive_high_1 object but maybe I should create new ones or just use `cv2.adaptiveThreshold` on the fly?
                # Actually, I should precompute them globally if I want speed, or just do it here since it's recovery (rare).
                # But to keep consistent, I will just do it on the fly for new thresholds.

                # C=0
                roi_rec_6 = cv2.adaptiveThreshold(
                    roi_gray_eq, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 11, 0)
                roi_rec_crop_6 = roi_rec_6[y_min:y_max, x_start:x_end_rec]
                res_6 = run_ocr_on_crop(roi_rec_crop_6)

                # C=4
                roi_rec_7 = cv2.adaptiveThreshold(
                    roi_gray_eq, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 11, 4)
                roi_rec_crop_7 = roi_rec_7[y_min:y_max, x_start:x_end_rec]
                res_7 = run_ocr_on_crop(roi_rec_crop_7)

                if debug:
                    print(f"      Recovery Pass 1 (-8): '{res_1}'")
                    print(f"      Recovery Pass 2 (-20): '{res_2}'")
                    print(f"      Recovery Pass 3 (-12): '{res_3}'")
                    print(f"      Recovery Pass 4 (2): '{res_4}'")
                    print(f"      Recovery Pass 5 (-4): '{res_5}'")
                    print(f"      Recovery Pass 6 (0): '{res_6}'")
                    print(f"      Recovery Pass 7 (4): '{res_7}'")

                final_recovery = None

                # Logic: Prefer '1'. If any pass finds '1', use it.
                candidates = [res_1, res_2, res_3, res_4, res_5, res_6, res_7]
                if debug:
                    print(f"      Candidates: {candidates}")

                has_3 = False
                has_1 = False
                for c in candidates:
                    if c and '3' in c:
                        has_3 = True
                    if c and '1' in c:
                        has_1 = True

                if has_3:
                    final_recovery = '3'
                elif has_1:
                    final_recovery = '1'
                else:
                    # Pick the first non-None
                    for c in candidates:
                        if c:
                            final_recovery = c
                            break

                if final_recovery:
                    # Overwrite Logic
                    if not set_score:
                        if debug:
                            print(
                                f"Recovered Missing Set Score: {final_recovery}")
                        set_score = final_recovery
                    # elif set_score == '2' and final_recovery == '1':
                    #     if debug:
                    #         print("Corrected Set Score '2' to '1'")
                    #     set_score = '1'
                    elif set_score == '4' and final_recovery == '1':
                        if debug:
                            print("Corrected Set Score '4' to '1'")
                        set_score = '1'
                    elif set_score and int(set_score) > 4:
                        if debug:
                            print(
                                f"Corrected Invalid Set Score '{set_score}' to '{final_recovery}'")
                        set_score = final_recovery

        parts = [name, set_score, game_score]

        if debug:
            print(f"Row {i+1}: {parts}")
        structured_result.append(parts)

    return structured_result


if __name__ == "__main__":
    path = '/home/sdanilov/Build/wtt-youtube-organizer/videos/clip-3300.0-0.001.jpg'
    analyze_scoreboard_smart(path)
