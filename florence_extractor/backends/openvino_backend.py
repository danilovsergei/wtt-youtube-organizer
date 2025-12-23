"""
Native OpenVINO backend for Florence-2 inference.
Uses Intel's official Florence-2 conversion and inference approach.
Provides actual GPU acceleration on Intel hardware.
"""

import sys
import os
from pathlib import Path
from PIL import Image

from .base import Florence2Backend


class OpenVINOBackend(Florence2Backend):
    """
    Florence-2 backend using native OpenVINO inference.

    This backend uses Intel's official approach for Florence-2:
    1. Converts PyTorch model to OpenVINO IR format
    2. Uses OVFlorence2Model wrapper for generation
    3. Runs inference on Intel GPU or CPU

    Reference: https://github.com/openvinotoolkit/openvino_notebooks
    """

    def __init__(self, model_path: str, device: str = "GPU"):
        """
        Initialize native OpenVINO backend.

        Args:
            model_path: Path to the Florence-2 model directory
            device: OpenVINO device ('GPU', 'CPU', 'AUTO')
        """
        self.model_path = Path(model_path)
        self.device = device
        self.model = None
        self.processor = None
        self._initialized = False
        self._ov_model_dir = None

    def initialize(self) -> bool:
        """Convert and load the Florence-2 model for OpenVINO inference."""
        if self._initialized:
            return True

        try:
            import torch
            from transformers import AutoProcessor

            # Import Intel's Florence-2 helper
            from .ov_florence2_helper import (
                convert_florence2,
                OVFlorence2Model,
                IMAGE_EMBEDDING_NAME
            )

            # Determine OV model directory
            self._ov_model_dir = self.model_path / "openvino"

            # Check if already converted
            if not (self._ov_model_dir / IMAGE_EMBEDDING_NAME).exists():
                print(f"Converting Florence-2 to OpenVINO format...")
                print(f"  Source: {self.model_path}")
                print(f"  Target: {self._ov_model_dir}")
                print("  (This is a one-time operation)")

                # Convert model to OpenVINO IR
                convert_florence2(
                    model_id=str(self.model_path),
                    output_dir=self._ov_model_dir,
                    orig_model_dir=self.model_path
                )
            else:
                print(f"Using pre-converted OpenVINO model from "
                      f"{self._ov_model_dir}")

            # Load processor
            print(f"Loading Florence-2 model (OpenVINO {self.device})...")
            self.processor = AutoProcessor.from_pretrained(
                self._ov_model_dir, trust_remote_code=True
            )

            # Load OpenVINO model
            ov_config = {}
            self.model = OVFlorence2Model(
                self._ov_model_dir,
                device=self.device,
                ov_config=ov_config
            )

            self._initialized = True
            print(f"Model ready on {self.device_info}")
            return True

        except ImportError as e:
            print(f"Required package not available: {e}")
            print("Install with: pip install openvino transformers")
            return False
        except Exception as e:
            print(f"Error initializing OpenVINO backend: {e}")
            import traceback
            traceback.print_exc()
            return False

    def generate_and_decode(self, image: Image.Image, prompt: str) -> str:
        """
        Generate text from image using Florence-2 with OpenVINO.

        Args:
            image: PIL Image to process
            prompt: Prompt string (e.g., "<OCR>")

        Returns:
            Decoded generated text
        """
        import torch

        if not self._initialized:
            raise RuntimeError(
                "Backend not initialized. Call initialize() first.")

        try:
            # Process inputs
            inputs = self.processor(
                text=prompt, images=image, return_tensors="pt"
            )

            # Run generation with OpenVINO model
            generated_ids = self.model.generate(
                input_ids=inputs["input_ids"],
                pixel_values=inputs["pixel_values"],
                max_new_tokens=1024,
                num_beams=1,
                do_sample=False
            )

            # Decode output
            generated_text = self.processor.batch_decode(
                generated_ids, skip_special_tokens=True
            )[0]

            return generated_text

        except Exception as e:
            print(f"[OpenVINO] Inference error: {e}")
            import traceback
            traceback.print_exc()
            raise

    def cleanup(self) -> None:
        """Free model resources."""
        if self.model is not None:
            del self.model
            self.model = None

        if self.processor is not None:
            del self.processor
            self.processor = None

        self._initialized = False

    @property
    def is_initialized(self) -> bool:
        """Check if the backend is initialized."""
        return self._initialized

    @property
    def device_info(self) -> str:
        """Return device information string."""
        try:
            import openvino as ov
            core = ov.Core()
            devices = core.available_devices

            if self.device == "GPU" and "GPU" in devices:
                try:
                    gpu_name = core.get_property("GPU", "FULL_DEVICE_NAME")
                    return f"OpenVINO GPU ({gpu_name})"
                except Exception:
                    return "OpenVINO GPU (Intel)"

            return f"OpenVINO ({self.device})"

        except Exception:
            return f"OpenVINO ({self.device})"
