"""
Florence-2 Backend Factory

Provides runtime selection of inference backends for Florence-2 model.
Supports: PyTorch (CPU/CUDA), OpenVINO (Intel GPU)
"""

from typing import List, TYPE_CHECKING

if TYPE_CHECKING:
    from .base import Florence2Backend

# Available backend types
BACKEND_PYTORCH_CPU = "pytorch-cpu"
BACKEND_PYTORCH_CUDA = "pytorch-cuda"
BACKEND_OPENVINO = "openvino"  # Native OpenVINO (requires pre-converted)

ALL_BACKENDS = [
    BACKEND_PYTORCH_CPU,
    BACKEND_PYTORCH_CUDA,
    BACKEND_OPENVINO
]


def get_available_backends() -> List[str]:
    """Return list of available backends based on installed packages."""
    available = []

    # PyTorch backends
    try:
        import torch
        available.append(BACKEND_PYTORCH_CPU)
        if torch.cuda.is_available():
            available.append(BACKEND_PYTORCH_CUDA)
    except ImportError:
        pass

    # Native OpenVINO backend
    try:
        import openvino as ov  # noqa: F401
        available.append(BACKEND_OPENVINO)
    except ImportError:
        pass

    return available


def create_backend(backend_type: str, model_path: str) -> "Florence2Backend":
    """
    Factory function to create a Florence-2 backend.

    Args:
        backend_type: One of the backend types (pytorch-cpu, pytorch-cuda,
                      openvino)
        model_path: Path to the Florence-2 model directory

    Returns:
        Initialized Florence2Backend instance

    Raises:
        ValueError: If backend_type is not recognized
        ImportError: If required packages are not installed
    """
    if backend_type == BACKEND_PYTORCH_CPU:
        from .pytorch_backend import PyTorchBackend
        return PyTorchBackend(model_path, device="cpu")

    elif backend_type == BACKEND_PYTORCH_CUDA:
        from .pytorch_backend import PyTorchBackend
        return PyTorchBackend(model_path, device="cuda")

    elif backend_type == BACKEND_OPENVINO:
        from .openvino_backend import OpenVINOBackend
        return OpenVINOBackend(model_path)

    else:
        raise ValueError(
            f"Unknown backend type: {backend_type}. "
            f"Available: {', '.join(ALL_BACKENDS)}"
        )


def get_default_backend() -> str:
    """
    Get the best default backend based on available hardware.

    Priority:
    1. Native OpenVINO (Intel GPU)
    2. PyTorch CUDA (NVIDIA GPU)
    3. PyTorch CPU (fallback)
    """
    available = get_available_backends()

    # Prefer native OpenVINO for Intel GPUs
    if BACKEND_OPENVINO in available:
        return BACKEND_OPENVINO

    # Then CUDA for NVIDIA GPUs
    if BACKEND_PYTORCH_CUDA in available:
        return BACKEND_PYTORCH_CUDA

    # Fallback to CPU
    if BACKEND_PYTORCH_CPU in available:
        return BACKEND_PYTORCH_CPU

    raise RuntimeError(
        "No backends available. Install torch or openvino"
    )
