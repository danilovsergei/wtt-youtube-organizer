# Florence Extractor Docker Image
# Uses OpenVINO base image for Intel GPU acceleration

# Match OpenVINO version with local training environment (2025.4.1)
FROM openvino/ubuntu22_runtime:2025.4.1

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Install system dependencies
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-dev \
    ffmpeg \
    curl \
    unzip \
    libgl1-mesa-glx \
    libglib2.0-0 \
    gpg-agent \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# Install Intel compute runtime for GPU support (compatible with Ubuntu 22.04)
# The base image's Level Zero may not include GPU drivers
RUN curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key | gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu jammy unified" > /etc/apt/sources.list.d/intel-gpu.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    intel-opencl-icd \
    intel-level-zero-gpu \
    level-zero \
    && rm -rf /var/lib/apt/lists/*

# Install Deno (required by yt-dlp for YouTube parsing)
RUN curl -fsSL https://deno.land/install.sh | sh
ENV DENO_INSTALL="/root/.deno"
ENV PATH="${DENO_INSTALL}/bin:${PATH}"

# Create app directory
WORKDIR /app

# Install pip dependencies
# Note: flash_attn is mocked in the code (requires CUDA, not needed for OpenVINO)
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel packaging

# Install PyTorch CPU-only (smaller image, OpenVINO handles inference)
RUN pip3 install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cpu

# Install core dependencies for Florence-2 + OpenVINO
# Pin transformers and tokenizers versions to match training environment
RUN pip3 install --no-cache-dir \
    einops \
    huggingface_hub \
    numpy \
    opencv-python-headless \
    pandas \
    Pillow \
    timm \
    tqdm \
    "transformers==4.57.6" \
    "tokenizers==0.22.2" \
    yt-dlp

# OpenVINO is already installed in the base image (2025.4.1)
# Install GPU plugin and nncf for model optimization support
RUN pip3 install --no-cache-dir nncf openvino-genai

# Copy the florence_extractor code (including OpenVINO model)
COPY . /app/florence_extractor/

# Ensure the OpenVINO model is bundled
# The model should exist at: florence2-tt-finetuned/openvino/
RUN test -d /app/florence_extractor/florence2-tt-finetuned/openvino || \
    echo "Warning: OpenVINO model not found. Build may fail at runtime."

# Create output directory
RUN mkdir -p /output

# Copy and set up entrypoint
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set working directory to project root
WORKDIR /app

ENTRYPOINT ["/entrypoint.sh"]
