# Florence Extractor Docker Image
# Uses NVIDIA CUDA base image for PyTorch GPU acceleration

FROM nvidia/cuda:12.1.1-runtime-ubuntu22.04

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
    && rm -rf /var/lib/apt/lists/*

# Install Deno (required by yt-dlp for YouTube parsing)
RUN curl -fsSL https://deno.land/install.sh | sh
ENV DENO_INSTALL="/root/.deno"
ENV PATH="${DENO_INSTALL}/bin:${PATH}"

# Configure yt-dlp to use Deno remote components for JS challenge solving
RUN mkdir -p /root/.config/yt-dlp && \
    echo "--remote-components ejs:github" > /root/.config/yt-dlp/config

# Create app directory
WORKDIR /app

# Install pip dependencies
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel packaging

# Install PyTorch with CUDA 12.1 support
# If you need to build custom wheels for the 1080 Ti (sm_61), you can COPY them into the image here and pip install the local wheel instead.
RUN pip3 install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cu121

# Install core dependencies for Florence-2
# Note: flash_attn is omitted as compiling it during docker build without a GPU attached can be problematic, 
# and Florence-2 will fallback gracefully without it or we can install a pre-compiled wheel if needed.
RUN pip3 install --no-cache-dir \
    einops \
    huggingface_hub \
    numpy \
    opencv-python-headless \
    pandas \
    Pillow \
    timm \
    tqdm \
    "transformers==4.45.1" \
    "tokenizers==0.20.4" \
    yt-dlp

# Copy the florence_extractor code
COPY florence_extractor /app/florence_extractor/

# Ensure the finetuned model is bundled
RUN test -d /app/florence_extractor/florence2-tt-finetuned || \
    echo "Warning: Fine-tuned model not found. Build may fail at runtime."

# Create output directory
RUN mkdir -p /output

# Copy and set up entrypoint
COPY florence_extractor/docker/cuda/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set working directory to project root
WORKDIR /app

ENTRYPOINT ["/entrypoint.sh"]
