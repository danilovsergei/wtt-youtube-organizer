from transformers import AutoProcessor, AutoModelForCausalLM
import cv2
import os
import glob
import csv
import re
import argparse
import sys
from pathlib import Path
from PIL import Image
from unittest.mock import MagicMock
from PIL import Image

# Add script directory to path for imports
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from ocr_utils import parse_score, ScoreResult, normalize_text, is_similar

# Configuration - Tune these values manually
BOTTOM_PERCENT = 0.14  # Fraction of height to crop from the bottom
LEFT_PERCENT = 0.40    # Fraction of width to crop from the left

from prod_video_processor import ScoreExtractor, get_device, get_default_backend, BACKEND_PYTORCH, BACKEND_OPENVINO, ALL_BACKENDS

def load_expected_data(csv_path):
    data = {}
    if not os.path.exists(csv_path):
        print(f"Warning: CSV file not found at {csv_path}")
        return data

    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            path = row.get('image path', '')
            filename = os.path.basename(path)
            if filename:
                data[filename] = row
    return data

def crop_images(input_dir, output_dir):
    print(f"--- Cropping Images from {input_dir} ---")

    if not os.path.exists(input_dir):
        print(f"Error: Input directory not found at {input_dir}")
        return

    if os.path.exists(output_dir):
        old_files = glob.glob(os.path.join(output_dir, '*.jpg'))
        if old_files:
            print(f"Cleaning {len(old_files)} old images from {output_dir}")
            for f in old_files:
                os.remove(f)
    else:
        os.makedirs(output_dir)
        print(f"Created output directory at {output_dir}")

    image_files = glob.glob(os.path.join(input_dir, '*.jpg'))

    if not image_files:
        print(f"No .jpg images found in {input_dir}")
        return

    print(f"Found {len(image_files)} images. Cropping...")

    for img_path in image_files:
        filename = os.path.basename(img_path)
        img = cv2.imread(img_path)

        if img is None:
            print(f"Warning: Could not read {filename}. Skipping.")
            continue

        h, w = img.shape[:2]
        y_start = int(h * (1 - BOTTOM_PERCENT))
        x_end = int(w * LEFT_PERCENT)
        cropped_img = img[y_start:h, 0:x_end]

        output_path = os.path.join(output_dir, filename)
        cv2.imwrite(output_path, cropped_img)

    print(f"Finished cropping {len(image_files)} images.")

def load_expected_data(csv_path):
    data = {}
    if not os.path.exists(csv_path):
        print(f"Warning: CSV file not found at {csv_path}")
        return data

    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            path = row.get('image path', '')
            filename = os.path.basename(path)
            if filename:
                data[filename] = row
    return data

def crop_images(input_dir, output_dir):
    print(f"--- Cropping Images from {input_dir} ---")

    if not os.path.exists(input_dir):
        print(f"Error: Input directory not found at {input_dir}")
        return

    if os.path.exists(output_dir):
        old_files = glob.glob(os.path.join(output_dir, '*.jpg'))
        if old_files:
            print(f"Cleaning {len(old_files)} old images from {output_dir}")
            for f in old_files:
                os.remove(f)
    else:
        os.makedirs(output_dir)
        print(f"Created output directory at {output_dir}")

    image_files = glob.glob(os.path.join(input_dir, '*.jpg'))

    if not image_files:
        print(f"No .jpg images found in {input_dir}")
        return

    print(f"Found {len(image_files)} images. Cropping...")

    for img_path in image_files:
        filename = os.path.basename(img_path)
        img = cv2.imread(img_path)

        if img is None:
            print(f"Warning: Could not read {filename}. Skipping.")
            continue

        h, w = img.shape[:2]
        y_start = int(h * (1 - BOTTOM_PERCENT))
        x_end = int(w * LEFT_PERCENT)
        cropped_img = img[y_start:h, 0:x_end]

        output_path = os.path.join(output_dir, filename)
        cv2.imwrite(output_path, cropped_img)

    print(f"Finished cropping {len(image_files)} images.")

def process_images(image_dir, csv_path, extractor, verify_mode=True):
    print(f"\n--- Running Florence-2 on {image_dir} ---")

    expected_data = load_expected_data(csv_path) if verify_mode else {}
    image_files = glob.glob(os.path.join(image_dir, '*.jpg'))

    if not image_files:
        print(f"No .jpg images found in {image_dir}")
        return

    print(f"Found {len(image_files)} images. Processing...")

    for img_path in image_files:
        filename = os.path.basename(img_path)

        try:
            pil_image = Image.open(img_path).convert("RGB")
        except Exception as e:
            print(f"Error reading image {filename}: {e}")
            continue

        score_result = extractor.extract_score(pil_image)
        generated_text = score_result.error if not score_result.success else 'Successfully extracted'

        if verify_mode:
            expected = expected_data.get(filename)
            passed = False
            mismatch_details = []

            if expected:
                exp_p1 = expected.get('row 1 expected player', '')
                exp_s1 = str(expected.get('row 1 set score', ''))
                exp_g1 = str(expected.get('row 1 game score', ''))

                act_p1 = score_result.player1 if score_result.success else ""
                act_s1 = str(score_result.set1) if score_result.success else ""
                act_g1 = str(score_result.game1) if score_result.success else ""

                # Handle defaulting -1 (which means could not parse game) as empty string
                if act_g1 == "-1":
                    act_g1 = ""

                # Print warning if it matches fuzzily but NOT strictly
                if normalize_text(exp_p1) != normalize_text(act_p1) and is_similar(exp_p1, act_p1):
                    print(f"  [HARD-MINING] Row 1 Player strictly mismatched (but fuzzy passed): Exp '{exp_p1}' != Act '{act_p1}'")

                if not is_similar(exp_p1, act_p1):
                    mismatch_details.append(
                        f"Row 1 Player: Exp '{exp_p1}' != Act '{act_p1}'")
                if exp_s1 != act_s1:
                    mismatch_details.append(
                        f"Row 1 Set: Exp '{exp_s1}' != Act '{act_s1}'")
                if exp_g1 != act_g1:
                    mismatch_details.append(
                        f"Row 1 Game: Exp '{exp_g1}' != Act '{act_g1}'")

                exp_p2 = expected.get('row 2 expected player 2', '')
                exp_s2 = str(expected.get('row 2 set score', ''))
                exp_g2 = str(expected.get('row 2 game score', ''))

                act_p2 = score_result.player2 if score_result.success else ""
                act_s2 = str(score_result.set2) if score_result.success else ""
                act_g2 = str(score_result.game2) if score_result.success else ""

                if act_g2 == "-1":
                    act_g2 = ""

                # Print warning if it matches fuzzily but NOT strictly
                if normalize_text(exp_p2) != normalize_text(act_p2) and is_similar(exp_p2, act_p2):
                    print(f"  [HARD-MINING] Row 2 Player strictly mismatched (but fuzzy passed): Exp '{exp_p2}' != Act '{act_p2}'")

                if not is_similar(exp_p2, act_p2):
                    mismatch_details.append(
                        f"Row 2 Player: Exp '{exp_p2}' != Act '{act_p2}'")
                if exp_s2 != act_s2:
                    mismatch_details.append(
                        f"Row 2 Set: Exp '{exp_s2}' != Act '{act_s2}'")
                if exp_g2 != act_g2:
                    mismatch_details.append(
                        f"Row 2 Game: Exp '{exp_g2}' != Act '{act_g2}'")

                if not mismatch_details:
                    passed = True
            else:
                mismatch_details.append("No expected data found in CSV")

            if passed:
                print(f"Image: {filename} - PASSED")
            else:
                print(f"Image: {filename} - FAILED")
                print(f"  Raw output: '{generated_text}'")
                for detail in mismatch_details:
                    print(f"  {detail}")
            print("-" * 20)
        else:
            print(f"Image: {filename}")
            if score_result.success:
                print(f"  Player 1: {score_result.player1}, "
                      f"Set: {score_result.set1}, Game: {score_result.game1 if score_result.game1 != -1 else ''}")
                print(f"  Player 2: {score_result.player2}, "
                      f"Set: {score_result.set2}, Game: {score_result.game2 if score_result.game2 != -1 else ''}")
            else:
                print(f"  Failed to parse: {score_result.error}")
            print("-" * 20)


def main():
    parser = argparse.ArgumentParser(
        description='Extract scores from table tennis images using Florence-2')
    parser.add_argument('--images_dir', type=str, required=True,
                        help='Directory containing input images')
    parser.add_argument('--cuda_device_id', type=int, default=None, help='The ID of the CUDA device to use for PyTorch (if multiple are available)')
    parser.add_argument('--cuda_device_name', type=str, default=None, help='The exact string name of the GPU to map via PyTorch (prevents index mismatch between nvidia-smi and torch)')
    parser.add_argument('--backend', type=str, default=None,
                        choices=ALL_BACKENDS,
                        help='Inference backend: pytorch-cpu or openvino '
                             '(default: openvino if available)')
    parser.add_argument('--crop', type=str, default=None,
                        choices=['true', 'false'],
                        help='Crop images before processing '
                             '(default: false for testdata, true otherwise)')
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))

    if os.path.isabs(args.images_dir):
        input_dir = args.images_dir
    else:
        input_dir = os.path.join(script_dir, args.images_dir)

    dir_name = os.path.basename(os.path.normpath(input_dir))
    verify_mode = (dir_name == 'testdata')

    # Determine crop setting: default false for testdata, true otherwise
    if args.crop is not None:
        do_crop = (args.crop == 'true')
    else:
        do_crop = not verify_mode  # False for testdata, True otherwise

    if verify_mode:
        print("Running in VERIFY mode (comparing with expected scores)")
        csv_path = os.path.join(script_dir, 'test_data_sample.csv')
    else:
        print("Running in PRINT mode (displaying extracted scores only)")
        csv_path = None

    # Determine backend
    backend = args.backend or get_default_backend()
    print(f"Backend: {backend}")
    print(f"Crop images: {do_crop}")

    # Initialize model
    device = get_device(args) if backend == BACKEND_PYTORCH else 'cpu'
    
    # Print the resolved device immediately
    dev_name_print = ""
    if str(device).startswith("cuda"):
        try:
            import torch
            idx = int(str(device).split(":")[1]) if ":" in str(device) else 0
            dev_name_print = f" ({torch.cuda.get_device_name(idx)})"
        except Exception:
            pass
    print(f"Resolved execution device: {device}{dev_name_print}")
    extractor = ScoreExtractor(backend=backend, device=device)

    if not extractor.initialize():
        print("Failed to initialize model")
        sys.exit(1)

    # Step 1: Crop images if enabled
    if do_crop:
        output_dir = os.path.join(script_dir, 'cropped_images')
        crop_images(input_dir, output_dir)
        process_dir = output_dir
    else:
        print("Skipping crop (images already cropped)")
        process_dir = input_dir

    # Step 2: Process images
    process_images(process_dir, csv_path, extractor, verify_mode=verify_mode)


if __name__ == "__main__":
    main()
