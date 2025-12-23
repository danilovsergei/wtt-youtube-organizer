#!/usr/bin/env python3
"""
Convert Florence-2 model to OpenVINO IR format.

This script converts a fine-tuned Florence-2 model to OpenVINO format
for GPU-accelerated inference on Intel hardware.

Usage:
    python florence_extractor/convert_to_openvino.py

    # Use custom model path:
    python florence_extractor/convert_to_openvino.py --model /path/to/model

    # Force reconversion (delete existing OpenVINO files):
    python florence_extractor/convert_to_openvino.py --force
"""

import argparse
import shutil
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))


def main():
    parser = argparse.ArgumentParser(
        description='Convert Florence-2 model to OpenVINO IR format')
    parser.add_argument(
        '--model', type=str,
        default=None,
        help='Path to Florence-2 model directory '
             '(default: florence_extractor/florence2-tt-finetuned)')
    parser.add_argument(
        '--force', action='store_true',
        help='Force reconversion by deleting existing OpenVINO files')
    args = parser.parse_args()

    # Determine model path
    if args.model:
        model_path = Path(args.model)
    else:
        # Default to florence2-tt-finetuned relative to this script
        script_dir = Path(__file__).parent
        model_path = script_dir / "florence2-tt-finetuned"

    if not model_path.exists():
        print(f"Error: Model directory not found: {model_path}")
        sys.exit(1)

    output_dir = model_path / "openvino"

    # Handle --force flag
    if args.force and output_dir.exists():
        print(f"Removing existing OpenVINO files: {output_dir}")
        shutil.rmtree(output_dir)

    print("Converting Florence-2 model to OpenVINO")
    print(f"  Source:      {model_path}")
    print(f"  Output:      {output_dir}")
    print()

    # Import here to avoid loading heavy dependencies unless needed
    from florence_extractor.backends.ov_florence2_helper import (
        convert_florence2
    )

    try:
        convert_florence2(
            model_id=str(model_path),
            output_dir=output_dir,
            orig_model_dir=model_path
        )
        print()
        print("✅ Conversion complete!")
        print(f"   OpenVINO model saved to: {output_dir}")
    except Exception as e:
        print(f"❌ Conversion failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
