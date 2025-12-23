"""
PyTorch backend for Florence-2 inference.
Supports CPU and CUDA (NVIDIA GPU) devices.
"""

import sys
from unittest.mock import MagicMock
from PIL import Image

from .base import Florence2Backend

# Mock flash_attn to avoid installation requirement
if "flash_attn" not in sys.modules:
    mock_flash_attn = MagicMock()
    mock_flash_attn.__spec__ = MagicMock()
    sys.modules["flash_attn"] = mock_flash_attn


class PyTorchBackend(Florence2Backend):
    """
    Florence-2 backend using PyTorch.

    Supports both CPU and CUDA (NVIDIA GPU) inference.
    """

    def __init__(self, model_path: str, device: str = "cpu"):
        """
        Initialize PyTorch backend.

        Args:
            model_path: Path to the Florence-2 model directory
            device: Device to run on ('cpu' or 'cuda')
        """
        self.model_path = model_path
        self.device = device
        self.model = None
        self.processor = None
        self._initialized = False

    def initialize(self) -> bool:
        """Load the Florence-2 model and processor."""
        if self._initialized:
            return True

        try:
            from transformers import AutoProcessor, AutoModelForCausalLM
            import torch

            # Validate device
            if self.device == "cuda" and not torch.cuda.is_available():
                print("CUDA requested but not available, falling back to CPU")
                self.device = "cpu"

            print(f"Loading Florence-2 model (PyTorch {self.device})...")

            self.processor = AutoProcessor.from_pretrained(
                self.model_path, trust_remote_code=True
            )
            self.model = AutoModelForCausalLM.from_pretrained(
                self.model_path,
                trust_remote_code=True,
                attn_implementation="eager"
            ).to(self.device)

            self._initialized = True
            print(f"Model loaded successfully on {self.device_info}")
            return True

        except Exception as e:
            print(f"Error loading Florence-2 model: {e}")
            return False

    def generate_and_decode(self, image: Image.Image, prompt: str) -> str:
        """
        Generate text from image using Florence-2.

        Args:
            image: PIL Image to process
            prompt: Prompt string (e.g., "<OCR>")

        Returns:
            Decoded generated text
        """
        if not self._initialized:
            raise RuntimeError(
                "Backend not initialized. Call initialize() first.")

        inputs = self.processor(
            text=prompt, images=image, return_tensors="pt"
        ).to(self.device)

        generated_ids = self.model.generate(
            input_ids=inputs["input_ids"],
            pixel_values=inputs["pixel_values"],
            max_new_tokens=1024,
            num_beams=1,
            do_sample=False,
            use_cache=False
        )

        generated_text = self.processor.batch_decode(
            generated_ids, skip_special_tokens=True
        )[0]

        return generated_text

    def cleanup(self) -> None:
        """Free model resources."""
        if self.model is not None:
            del self.model
            self.model = None

        if self.processor is not None:
            del self.processor
            self.processor = None

        self._initialized = False

        # Try to free GPU memory if using CUDA
        if self.device == "cuda":
            try:
                import torch
                torch.cuda.empty_cache()
            except Exception:
                pass

    @property
    def is_initialized(self) -> bool:
        """Check if the backend is initialized."""
        return self._initialized

    @property
    def device_info(self) -> str:
        """Return device information string."""
        if self.device == "cuda":
            try:
                import torch
                if torch.cuda.is_available():
                    gpu_name = torch.cuda.get_device_name(0)
                    return f"CUDA ({gpu_name})"
            except Exception:
                pass
            return "CUDA"
        return "CPU (PyTorch)"
