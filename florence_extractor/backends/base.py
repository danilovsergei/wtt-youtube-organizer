"""
Abstract base class for Florence-2 inference backends.
"""

from abc import ABC, abstractmethod
from PIL import Image


class Florence2Backend(ABC):
    """
    Abstract base class defining the interface for Florence-2 backends.

    All backends must implement these methods to be compatible with
    the score extraction pipeline.
    """

    @abstractmethod
    def initialize(self) -> bool:
        """
        Initialize the model and processor.

        Returns:
            True if initialization succeeded, False otherwise
        """
        pass

    @abstractmethod
    def generate_and_decode(self, image: Image.Image, prompt: str) -> str:
        """
        Generate text from image using the Florence-2 model.

        Args:
            image: PIL Image to process
            prompt: Prompt string (e.g., "<OCR>")

        Returns:
            Decoded generated text
        """
        pass

    @abstractmethod
    def cleanup(self) -> None:
        """
        Clean up resources (free memory, unload model, etc.)
        """
        pass

    @property
    @abstractmethod
    def is_initialized(self) -> bool:
        """Check if the backend is initialized and ready."""
        pass

    @property
    @abstractmethod
    def device_info(self) -> str:
        """Return human-readable device information."""
        pass
