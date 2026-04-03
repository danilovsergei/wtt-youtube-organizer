# Use NVIDIA CUDA 12.8 base for Blackwell (RTX 5070 Ti) support
FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04

# Arguments for Flash Attention and GPU SM
ARG FLASH_REQUIRED=false
ARG GPU_SM=120

# Prevent interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
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

# 2. Hard-Lock Installation of local Torch 2.10.0
# We do this FIRST so all subsequent installs see this specific version
RUN echo "🔥 FORCING LOCAL TORCH 2.10.0 ---" && \
    pip3 install --no-cache-dir --no-index --find-links=/tmp/wheels/ torch==2.10.0

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
RUN echo "📦 Installing remaining dependencies..." && \
    pip3 install --no-cache-dir \
    einops \
    "huggingface_hub>=0.23.2,<1.0" \
    "tokenizers>=0.19,<0.20" \
    safetensors \
    numpy \
    opencv-python-headless \
    pandas \
    Pillow \
    tqdm \
    requests \
    pyyaml \
    regex \
    packaging \
    filelock && \
    echo "🖼️  Installing Torchvision (FORCING 2.10 compatibility)..." && \
    # THE CRITICAL CHANGE: We explicitly tell pip that torch MUST be 2.10.0 
    # while it looks for a compatible torchvision.
    pip3 install --no-cache-dir "torch==2.10.0" torchvision --index-url https://download.pytorch.org/whl/cu128 && \
    echo "🤖 Installing Transformers stack..." && \
    pip3 install --no-cache-dir --no-deps timm "transformers==4.44.2"

# 5. FINAL VERIFICATION: Universal shell syntax (works in Dash and Bash)
# This confirms the version didn't drift during the torchvision/transformers steps
RUN echo "🛡️ FINAL VERSION CHECK ---" && \
    INSTALLED_VER=$(python3 -c "import torch; print(torch.__version__)") && \
    echo "Detected Torch: $INSTALLED_VER" && \
    case "$INSTALLED_VER" in \
    2.10.0*) echo "✅ Version Verified." ;; \
    *) echo "❌ FATAL: Torch version drift! Expected 2.10.0, got $INSTALLED_VER"; exit 1 ;; \
    esac

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