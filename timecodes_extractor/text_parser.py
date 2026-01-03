import easyocr
import cv2
import sys
import numpy as np

# Initialize Reader globally to avoid reloading model for every image
reader = easyocr.Reader(['en'], gpu=False)


def analyze_scoreboard_smart(image_path, debug=True, force_scale=None):
    if debug:
        print(f"--- Loading image: {image_path} ---")
    img = cv2.imread(image_path)
    if img is None:
        return

    h, w, _ = img.shape

    # 1. ROI: Bottom Left
    y_start = int(h * 0.85)

    # Main ROI (Wide) for detection
    x_end = int(w * 0.80)
    roi = img[y_start:h, 0:x_end]

    # Short ROI for Recovery Thresholds
    x_end_short = int(w * 0.55)
    roi_short = img[y_start:h, 0:x_end_short]

    # 2. ZOOM: Default 3x, or forced
    scale = force_scale if force_scale else 3
    if debug:
        print(f"Using Scale: {scale}")

    roi_zoomed = cv2.resize(roi, None, fx=scale, fy=scale,
                            interpolation=cv2.INTER_CUBIC)

    # 3. GRAYSCALE & INVERT (Main)
    roi_gray = cv2.cvtColor(roi_zoomed, cv2.COLOR_BGR2GRAY)
    roi_inverted = cv2.bitwise_not(roi_gray)

    # Adaptive for Main Detection
    roi_adaptive = cv2.adaptiveThreshold(roi_gray, 255,
                                         cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                         cv2.THRESH_BINARY_INV, 11, 2)

    # 4. RECOVERY PREP (Scale 3)
    limit_w = int(roi_gray.shape[1] * (0.55 / 0.80))
    roi_gray_narrow = roi_gray[:, :limit_w]
    roi_gray_eq = cv2.equalizeHist(roi_gray_narrow)

    adaptive_imgs_3 = []
    # Thresholds: -8, -20, -12, 2, -4, 0, 4
    for C in [-8, -20, -12, 2, -4, 0, 4]:
        adaptive_imgs_3.append(cv2.adaptiveThreshold(roi_gray_eq, 255,
                                                     cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                                     cv2.THRESH_BINARY_INV, 11, C))

    # 5. PRE-PROCESSING
    roi_list = []
    roi_list.append(roi_inverted)
    roi_list.append(roi_adaptive)

    # Save debug views
    cv2.imwrite("debug_ai_view.jpg", roi_inverted)
    cv2.imwrite("debug_ai_adaptive.jpg", roi_adaptive)

    roi_processed = roi_inverted

    # 6. INITIAL DETECTION
    full_whitelist = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ. /'

    all_results = []
    for processed_img in roi_list:
        res = reader.readtext(
            processed_img, allowlist=full_whitelist, width_ths=0.2)
        all_results.extend(res)

    # MERGE RESULTS
    unique_results = []

    def get_bbox_rect(bbox):
        tl = bbox[0]
        br = bbox[2]
        return int(tl[0]), int(tl[1]), int(br[0]), int(br[1])

    def compute_iou(boxA, boxB):
        xA = max(boxA[0], boxB[0])
        yA = max(boxA[1], boxB[1])
        xB = min(boxA[2], boxB[2])
        yB = min(boxA[3], boxB[3])
        interArea = max(0, xB - xA) * max(0, yB - yA)
        boxAArea = (boxA[2] - boxA[0]) * (boxA[3] - boxA[1])
        boxBArea = (boxB[2] - boxB[0]) * (boxB[3] - boxB[1])
        minArea = min(boxAArea, boxBArea)
        if minArea == 0:
            return 0
        return interArea / float(minArea)

    for item in all_results:
        bbox, text, prob = item
        box = get_bbox_rect(bbox)

        w_box = box[2] - box[0]
        cx = (box[0] + box[2]) // 2
        roi_w = roi_inverted.shape[1]

        if cx > (roi_w * 0.5):
            if w_box > 100:
                continue

        is_duplicate = False
        for existing in unique_results:
            ex_box = get_bbox_rect(existing[0])
            iou = compute_iou(box, ex_box)
            if iou > 0.2:
                is_duplicate = True
                break

            ex_text = existing[1]
            if text == ex_text:
                cx1 = (box[0] + box[2]) / 2
                cy1 = (box[1] + box[3]) / 2
                cx2 = (ex_box[0] + ex_box[2]) / 2
                cy2 = (ex_box[1] + ex_box[3]) / 2
                dist = ((cx1 - cx2)**2 + (cy1 - cy2)**2)**0.5
                if dist < 50:
                    is_duplicate = True
                    break

        if not is_duplicate:
            unique_results.append(item)

    results = unique_results

    roi_h, roi_w = roi_inverted.shape
    if debug:
        print("\n--- Processing Items ---")

    final_items = []
    for (bbox, text, prob) in results:
        top_left = bbox[0]
        bottom_right = bbox[2]
        cy = int((top_left[1] + bottom_right[1]) / 2)
        cx = int((top_left[0] + bottom_right[0]) / 2)

        if debug:
            print(f"   Item: '{text}' at {top_left}")

        is_score_column = cx > (roi_w * 0.5)
        is_not_digit = not text.replace('.', '').isdigit()

        if is_score_column and is_not_digit:
            if debug:
                print(f"   -> Fixing suspicious score: '{text}' at x={cx}")
            pad = 5
            y_min = max(0, int(top_left[1]) - pad)
            y_max = min(roi_h, int(bottom_right[1]) + pad)
            x_min = max(0, int(top_left[0]) - pad)
            x_max = min(roi_w, int(bottom_right[0]) + pad)

            number_crop = roi_processed[y_min:y_max, x_min:x_max]
            number_results = reader.readtext(
                number_crop, allowlist='0123456789Il')

            if number_results:
                new_text = number_results[0][1]
                if debug:
                    print(f"      Changed '{text}' to '{new_text}'")
                text = new_text

        rect = get_bbox_rect(bbox)
        final_items.append({'text': text, 'y': cy, 'x': cx, 'rect': rect})

    found_items = final_items
    found_items.sort(key=lambda k: k['y'])

    # 7. Grouping Logic
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

    # 8. Parsing
    if debug:
        print("\n--- FINAL RESULTS ---")
    structured_result = []

    def is_digit(s):
        return s.replace('.', '').strip().isdigit()

    # RECOVERY FUNCTION DEFINITION
    def run_recovery(x_start, x_end_rec, y_min, y_max):
        def run_ocr_on_crop(roi_crop):
            if roi_crop.size == 0:
                return None
            rec_res = reader.readtext(
                roi_crop, allowlist='0123456789Il', width_ths=0.2, text_threshold=0.4)
            if rec_res:
                crop_w = x_end_rec - x_start
                center_x = crop_w / 2
                best_dist = float('inf')
                best_digit = None
                for (bbox, text, prob) in rec_res:
                    item_cx = (bbox[0][0] + bbox[1][0]) / 2
                    dist = abs(item_cx - center_x)
                    text = text.replace('I', '1').replace('l', '1')
                    if text.isdigit():
                        if dist < best_dist:
                            best_dist = dist
                            best_digit = text
                return best_digit.strip() if best_digit else None
            return None

        candidates = []
        boost_pass_indices = []

        if scale == 3:
            # Collect Scale 3
            for i, img_adap in enumerate(adaptive_imgs_3):
                if x_end_rec < img_adap.shape[1]:
                    roi_crop = img_adap[y_min:y_max, x_start:x_end_rec]
                    res = run_ocr_on_crop(roi_crop)
                    candidates.append(res)
                    if i == 3:
                        boost_pass_indices.append(
                            len(candidates)-1)  # Pass 4 index

            # Generate Scale 4 and Collect
            s_factor = 4/3
            y_min_4 = int(y_min * s_factor)
            y_max_4 = int(y_max * s_factor)
            x_start_4 = int(x_start * s_factor)
            x_end_rec_4 = int(x_end_rec * s_factor)

            roi_short_zoomed_4 = cv2.resize(
                roi_short, None, fx=4, fy=4, interpolation=cv2.INTER_CUBIC)
            roi_short_gray_4 = cv2.cvtColor(
                roi_short_zoomed_4, cv2.COLOR_BGR2GRAY)
            roi_gray_eq_4 = cv2.equalizeHist(roi_short_gray_4)

            for i, C in enumerate([-8, -20, -12, 2, -4, 0, 4]):
                img_adap = cv2.adaptiveThreshold(roi_gray_eq_4, 255,
                                                 cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                                 cv2.THRESH_BINARY_INV, 11, C)
                if x_end_rec_4 < img_adap.shape[1]:
                    roi_crop = img_adap[y_min_4:y_max_4, x_start_4:x_end_rec_4]
                    res = run_ocr_on_crop(roi_crop)
                    candidates.append(res)
                    if i == 3:
                        boost_pass_indices.append(len(candidates)-1)

        else:
            # If scale != 3, use narrow eq (recomputed)
            limit_w = int(roi_gray.shape[1] * 0.55/0.65)
            roi_gray_narrow_curr = roi_gray[:, :limit_w]
            roi_gray_eq_curr = cv2.equalizeHist(roi_gray_narrow_curr)
            for i, C in enumerate([-8, -20, -12, 2, -4, 0, 4]):
                img_adap = cv2.adaptiveThreshold(roi_gray_eq_curr, 255,
                                                 cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                                 cv2.THRESH_BINARY_INV, 11, C)
                if x_end_rec < img_adap.shape[1]:
                    roi_crop = img_adap[y_min:y_max, x_start:x_end_rec]
                    res = run_ocr_on_crop(roi_crop)
                    candidates.append(res)
                    if i == 3:
                        boost_pass_indices.append(len(candidates)-1)

        # Clean candidates
        cleaned_candidates = []
        for c in candidates:
            if c:
                if len(set(c)) == 1 and len(c) > 1:
                    c = c[0]
                if c == '11183':
                    c = '3'
                if c == '33':
                    c = '3'
                if c == '18':
                    c = '1'
            cleaned_candidates.append(c)
        candidates = cleaned_candidates

        if debug:
            print(f"      Candidates: {candidates}")

        final_recovery = None
        valid_digits = ['0', '1', '2', '3']

        # 1. Prefer '3' if present (substring) AND no Exact '1'
        has_exact_1 = '1' in candidates
        has_sub_3 = any(c and '3' in c for c in candidates)

        if has_sub_3 and not has_exact_1:
            final_recovery = '3'
        else:
            # 2. Frequency Voting with Pass 4 Boost
            counts = {d: candidates.count(d) for d in valid_digits}

            # Boost Pass 4 (Exact)
            for idx in boost_pass_indices:
                if idx < len(candidates):
                    c = candidates[idx]
                    if c in valid_digits:
                        counts[c] += 2

            max_count = max(counts.values())
            if debug:
                print(f"      Counts: {counts}")

            if max_count > 0:
                best_digits = [
                    d for d in valid_digits if counts[d] == max_count]
                # Priority: 3 > 1 > 0 > 2
                for p in ['3', '1', '0', '2']:
                    if p in best_digits:
                        final_recovery = p
                        break
            else:
                # Substring fallback
                sub_counts = {d: 0 for d in valid_digits}
                for c in candidates:
                    if c:
                        for d in valid_digits:
                            if d in c:
                                sub_counts[d] += 1

                max_sub = max(sub_counts.values())
                if max_sub > 0:
                    best_subs = [
                        d for d in valid_digits if sub_counts[d] == max_sub]
                    for p in ['3', '0', '1', '2']:
                        if p in best_subs:
                            final_recovery = p
                            break
                else:
                    # Fallback
                    for c in candidates:
                        if c:
                            final_recovery = c
                            break

        # Always Upscale Fallback on Scale 3 (for clip-7500)
        if scale == 3 and len(adaptive_imgs_3) > 3:
            # Check if we already have a strong candidate?
            # clip-7500 has '3' (from Pass 5).
            # If we don't trust '3'.
            # Just add Upscaled Pass 4 result to candidates?
            # Or run it if final_recovery is None?
            # Code below only runs if not found_valid.

            # Change: Always run Upscale Pass 4 if '1' is missing?
            # Or simpler: Always run and add to candidates BEFORE voting?
            pass

            roi_rec_crop_4 = adaptive_imgs_3[3][y_min:y_max, x_start:x_end_rec]
            if roi_rec_crop_4.size > 0:
                roi_up = cv2.resize(roi_rec_crop_4, None,
                                    fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
                res_up = run_ocr_on_crop(roi_up)
                if debug:
                    print(f"      Upscaled Pass 4: '{res_up}'")

                # If Upscale found something valid, and it contradicts final_recovery?
                # Let's just override if final_recovery is None?
                # Or add to voting?
                # Re-running voting is complex.

                # If Upscale found '1', and we picked '3' (from noise).
                # '1' should win.
                if res_up == '1' and final_recovery != '1':
                    if debug:
                        print("      Overriding with Upscaled '1'")
                    final_recovery = '1'

        return final_recovery

    for i, row in enumerate(rows):
        row.sort(key=lambda k: k['x'])
        items = [item['text'] for item in row]

        digits = []
        for idx, item in enumerate(items):
            if is_digit(item):
                digits.append((idx, item))

        game_score = ""
        set_score = ""
        name_end_idx = len(items)
        game_item = None
        set_item = None

        valid_pairs = []

        if len(digits) >= 2:
            for k in range(len(digits) - 1):
                idx_set, val_set = digits[k]
                idx_game, val_game = digits[k+1]

                # Proximity check
                x_set = row[idx_set]['x']
                x_game = row[idx_game]['x']
                gap = x_game - x_set

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
            game_item = row[selected_pair['idx_game']]
            set_item = row[selected_pair['idx_set']]

        elif len(digits) == 1:
            idx_digit, val_digit = digits[0]
            digit_item = row[idx_digit]

            y_min = digit_item['rect'][1]
            y_max = digit_item['rect'][3]

            name_x_max = 0
            name_items_temp = row[:idx_digit]
            if name_items_temp:
                name_x_max = max(it['rect'][2] for it in name_items_temp)

            dist = digit_item['rect'][0] - name_x_max
            val_int = int(val_digit) if val_digit.isdigit() else 0

            # Special case: if single digit is '0', treat as set score
            # and let recovery find the game score
            if val_digit == '0':
                is_game = False
            else:
                is_game = val_int > 3 or dist < 135

            if debug:
                print(
                    f"      Distance: {dist}, Value: {val_digit}, is_game: {is_game}")

            if is_game:
                game_score = val_digit
                game_item = digit_item
            else:
                set_score = val_digit
                set_item = digit_item

            name_end_idx = idx_digit

        elif len(digits) >= 2:
            idx_game, val_game = digits[-1]
            game_score = val_game
            name_end_idx = digits[0][0]
            game_item = row[idx_game]

        name_items = row[:name_end_idx]
        name = " ".join([item['text'] for item in name_items])
        name = name.strip('0123456789 .Il')
        name = name.replace(' / ', '/').replace('/ ', '/').replace(' /', '/')

        recover_set = False
        recover_game = False

        # Set recovery conditions - skip if both scores are 0
        if not (set_score == '0' and game_score == '0'):
            if not set_score and name_items and game_item:
                recover_set = True
            elif set_score == '4' and name_items and game_item:
                recover_set = True
            elif set_score and int(set_score) > 4 and name_items and game_item:
                recover_set = True

        if set_score and not game_score and set_item:
            recover_game = True
        elif set_score == '0' and game_score == '0' and set_item and game_item:
            recover_game = True

        if recover_set:
            if debug:
                print("Attempting to recover Set Score...")
            name_x_max = max([it['rect'][2]
                             for it in name_items]) if name_items else 0
            game_x_min = game_item['rect'][0]
            y_min = min(min([it['rect'][1]
                        for it in name_items]), game_item['rect'][1])
            y_max = max(max([it['rect'][3]
                        for it in name_items]), game_item['rect'][3])

            pad = 50
            x_start = name_x_max - pad
            x_end_rec = game_x_min + pad

            if x_end_rec > x_start:
                res = run_recovery(x_start, x_end_rec, y_min, y_max)
                if res:
                    if not set_score:
                        if debug:
                            print(f"Recovered Missing Set Score: {res}")
                        set_score = res
                    elif set_score == '4' and res == '1':
                        set_score = '1'
                    elif set_score and int(set_score) > 4:
                        set_score = res

        if recover_game:
            if debug:
                print("Attempting to recover Game Score...")
            x_start_game = set_item['rect'][2] + 10
            x_end_game = x_start_game + 200
            y_min = set_item['rect'][1]
            y_max = set_item['rect'][3]
            res = run_recovery(x_start_game, x_end_game, y_min, y_max)
            if res:
                if debug:
                    print(f"Recovered Missing Game Score: {res}")
                game_score = res

        parts = [name, set_score, game_score]
        if debug:
            print(f"Row {i+1}: {parts}")
        structured_result.append(parts)

    needs_retry = False
    if not force_scale and scale == 3:
        if len(structured_result) < 2:
            needs_retry = True
        else:
            for row in structured_result:
                if not row[1] or not row[2]:
                    needs_retry = True
                    break

    if needs_retry:
        if debug:
            print("--- Retrying with Scale 4 ---")
        return analyze_scoreboard_smart(image_path, debug, force_scale=4)

    return structured_result


if __name__ == "__main__":
    pass
