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

# Mock flash_attn to avoid installation requirement
mock_flash_attn = MagicMock()
mock_flash_attn.__spec__ = MagicMock()
sys.modules["flash_attn"] = mock_flash_attn

# Add script directory to path for imports
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)


# Configuration - Tune these values manually
BOTTOM_PERCENT = 0.14  # Fraction of height to crop from the bottom
LEFT_PERCENT = 0.40    # Fraction of width to crop from the left

# Backend constants
BACKEND_PYTORCH = "pytorch-cpu"
BACKEND_OPENVINO = "openvino"
ALL_BACKENDS = [BACKEND_PYTORCH, BACKEND_OPENVINO]


def get_default_backend() -> str:
    """Get default backend - use openvino if available, else pytorch."""
    try:
        import openvino  # noqa: F401
        return BACKEND_OPENVINO
    except ImportError:
        return BACKEND_PYTORCH


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


def normalize_text(text):
    return re.sub(r'[^A-Z0-9]', '', text.upper())


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


class ScoreExtractor:
    """Handles score extraction using Florence-2 OCR model."""

    def __init__(self, model_path: str, backend: str = None):
        self.model_path = model_path
        self._backend = backend or get_default_backend()
        self.processor = None
        self.model = None
        self._ov_model = None
        self._initialized = False

    def initialize(self) -> bool:
        """Load the Florence-2 model using selected backend."""
        if self._initialized:
            return True

        if self._backend == BACKEND_OPENVINO:
            return self._initialize_openvino()
        else:
            return self._initialize_pytorch()

    def _initialize_pytorch(self) -> bool:
        """Initialize PyTorch backend."""
        print("Loading Florence-2 model (PyTorch CPU)...")
        try:
            self.processor = AutoProcessor.from_pretrained(
                self.model_path, trust_remote_code=True)
            self.model = AutoModelForCausalLM.from_pretrained(
                self.model_path, trust_remote_code=True,
                attn_implementation="eager").to("cpu")
            self._initialized = True
            print("Model loaded successfully.")
            return True
        except Exception as e:
            print(f"Error loading Florence-2 model: {e}")
            return False

    def _initialize_openvino(self) -> bool:
        """Initialize OpenVINO backend for GPU acceleration."""
        print("Loading Florence-2 model (OpenVINO GPU)...")
        try:
            from backends.ov_florence2_helper import (
                OVFlorence2Model
            )

            ov_model_dir = Path(self.model_path) / "openvino"

            self.processor = AutoProcessor.from_pretrained(
                ov_model_dir, trust_remote_code=True)

            self._ov_model = OVFlorence2Model(
                ov_model_dir, device="GPU", ov_config={})

            self._initialized = True
            print("Model loaded successfully (OpenVINO GPU).")
            return True
        except FileNotFoundError as e:
            print(f"Error: {e}")
            return False
        except Exception as e:
            print(f"Error loading OpenVINO model: {e}")
            print("Falling back to PyTorch...")
            self._backend = BACKEND_PYTORCH
            return self._initialize_pytorch()

    def extract(self, pil_image: Image.Image) -> str:
        """Extract text from image using OCR."""
        if not self._initialized:
            raise RuntimeError("Model not initialized")

        prompt = "<OCR>"
        inputs = self.processor(
            text=prompt, images=pil_image, return_tensors="pt")

        if self._backend == BACKEND_OPENVINO:
            generated_ids = self._ov_model.generate(
                input_ids=inputs["input_ids"],
                pixel_values=inputs["pixel_values"],
                max_new_tokens=1024,
                num_beams=1,
                do_sample=False
            )
        else:
            inputs = inputs.to("cpu")
            generated_ids = self.model.generate(
                input_ids=inputs["input_ids"],
                pixel_values=inputs["pixel_values"],
                max_new_tokens=1024,
                num_beams=1,
                do_sample=False,
                use_cache=False
            )

        return self.processor.batch_decode(
            generated_ids, skip_special_tokens=True)[0]


def parse_ocr_output(generated_text):
    """Parse Florence-2 output to extract player and score data."""
    processed_rows = []
    try:
        pattern = (
            r"row 1:\s*(.*?),\s*(\d+)(?:[,.\s/&-]+| and )(\d+)\s*"
            r"row 2:\s*(.*?),\s*(\d+)(?:[,.\s/&-]+| and )(\d+)"
        )
        match = re.search(pattern, generated_text)

        if match:
            processed_rows.append({
                'player': match.group(1).strip(),
                'set': match.group(2).strip(),
                'game': match.group(3).strip()
            })
            processed_rows.append({
                'player': match.group(4).strip(),
                'set': match.group(5).strip(),
                'game': match.group(6).strip()
            })
        else:
            print(f"  Warning: Could not parse: '{generated_text}'")
            processed_rows = [
                {'player': '', 'set': '', 'game': ''},
                {'player': '', 'set': '', 'game': ''}
            ]
    except Exception as e:
        print(f"  Error parsing output: {e}")
        processed_rows = [
            {'player': '', 'set': '', 'game': ''},
            {'player': '', 'set': '', 'game': ''}
        ]

    return processed_rows


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

        generated_text = extractor.extract(pil_image)
        processed_rows = parse_ocr_output(generated_text)

        if verify_mode:
            expected = expected_data.get(filename)
            passed = False
            mismatch_details = []

            if expected:
                exp_p1 = expected.get('row 1 expected player', '')
                exp_s1 = expected.get('row 1 set score', '')
                exp_g1 = expected.get('row 1 game score', '')

                act_p1 = processed_rows[0]['player'] if processed_rows else ""
                act_s1 = processed_rows[0]['set'] if processed_rows else ""
                act_g1 = processed_rows[0]['game'] if processed_rows else ""

                if normalize_text(exp_p1) != normalize_text(act_p1):
                    mismatch_details.append(
                        f"Row 1 Player: Exp '{exp_p1}' != Act '{act_p1}'")
                if exp_s1 != act_s1:
                    mismatch_details.append(
                        f"Row 1 Set: Exp '{exp_s1}' != Act '{act_s1}'")
                if exp_g1 != act_g1:
                    mismatch_details.append(
                        f"Row 1 Game: Exp '{exp_g1}' != Act '{act_g1}'")

                exp_p2 = expected.get('row 2 expected player 2', '')
                exp_s2 = expected.get('row 2 set score', '')
                exp_g2 = expected.get('row 2 game score', '')

                act_p2 = processed_rows[1]['player'] if len(
                    processed_rows) > 1 else ""
                act_s2 = processed_rows[1]['set'] if len(
                    processed_rows) > 1 else ""
                act_g2 = processed_rows[1]['game'] if len(
                    processed_rows) > 1 else ""

                if normalize_text(exp_p2) != normalize_text(act_p2):
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
                for detail in mismatch_details:
                    print(f"  {detail}")
            print("-" * 20)
        else:
            print(f"Image: {filename}")
            if len(processed_rows) > 0:
                p1 = processed_rows[0]
                print(f"  Player 1: {p1['player']}, "
                      f"Set: {p1['set']}, Game: {p1['game']}")
            if len(processed_rows) > 1:
                p2 = processed_rows[1]
                print(f"  Player 2: {p2['player']}, "
                      f"Set: {p2['set']}, Game: {p2['game']}")
            print("-" * 20)


def main():
    parser = argparse.ArgumentParser(
        description='Extract scores from table tennis images using Florence-2')
    parser.add_argument('--images_dir', type=str, required=True,
                        help='Directory containing input images')
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
    model_path = os.path.join(script_dir, "florence2-tt-finetuned")
    extractor = ScoreExtractor(model_path, backend=backend)

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
