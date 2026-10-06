# Use NVIDIA CUDA 12.8 base for Blackwell (RTX 5070 Ti) support
FROM nvidia/cuda:13.0.0-runtime-ubuntu22.04

# Arguments for Flash Attention and GPU SM
ARG FLASH_REQUIRED=false
ARG GPU_SM=120

# Prevent interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    python3-pip \
    python3-dev \
    curl \
    git \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Deno
RUN curl -fsSL https://deno.land/x/install/install.sh | sh
ENV DENO_INSTALL="/root/.deno"
ENV PATH="$DENO_INSTALL/bin:$PATH"

WORKDIR /app

# Upgrade base python tools
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel packaging

# 1. Stage the wheels
RUN mkdir -p /tmp/wheels
COPY wheels/*.whl* /tmp/wheels/

# 3. Install Flash Attention if requested (Blackwell sm_120)
RUN if [ "$FLASH_REQUIRED" = "true" ]; then \
    WHEEL=$(ls /tmp/wheels/flash_attn*sm120*.whl 2>/dev/null | head -n 1); \
    if [ -n "$WHEEL" ]; then \
    echo "🚀 Installing optimized Flash Attention for sm_$GPU_SM..."; \
    pip3 install --no-cache-dir "$WHEEL"; \
    else \
    echo "❌ ERROR: Flash required but no sm120 wheel found!"; exit 1; \
    fi; \
    fi

# 4. Install other dependencies with STRICT pinning
RUN echo "📦 Installing dependencies..." && \
    pip3 install --no-cache-dir \
    av \
    opencv-python-headless \
    einops \
    huggingface_hub \
    tokenizers \
    httpx \
    ninja \
    packaging \
    pillow \
    "transformers>=4.49.0" \
    qwen-vl-utils \
    accelerate \
    peft \
    timm && \
    echo "🤖 Installing PyTorch cu130 LAST to override any CPU versions..." && \
    pip3 install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cu130 --force-reinstall
ENV HF_HOME="/root/.cache/huggingface"
ENV HF_HUB_OFFLINE=1

# Clean up wheels to keep image size down
RUN rm -rf /tmp/wheels

# Copy application code
COPY florence_extractor /app/florence_extractor/
ENV PATH="/app/florence_extractor/docker/cuda/ffmpeg/bin:$PATH"


# Create output directory
RUN mkdir -p /output

# Entrypoint setup
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]