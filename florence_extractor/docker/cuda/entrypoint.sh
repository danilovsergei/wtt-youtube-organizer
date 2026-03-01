#!/bin/bash
set -e

SCRIPT_ARGS=("$@")

# Update yt-dlp to the latest version before every run
echo "Updating yt-dlp to the latest version..."
pip install --no-cache-dir -U yt-dlp

# Pre-download yt-dlp remote components for JS challenge solving (Deno)
echo "Downloading yt-dlp remote components..."
yt-dlp --remote-components ejs:github --version 2>&1 || echo "Warning: Failed to pre-download remote components"
echo "Deno version: $(deno --version 2>&1 | head -1)"

# Debug: Check CUDA availability
echo ""
echo "=== CUDA Debug ==="
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi
else
    echo "nvidia-smi not found. GPU may not be accessible to container."
fi
echo ""
python3 -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'Device count: {torch.cuda.device_count()}')
    for i in range(torch.cuda.device_count()):
        print(f'  Device {i}: {torch.cuda.get_device_name(i)}')
"
echo "=================="
echo ""

# Ensure backend is set to pytorch for the cuda image
HAS_BACKEND=false
for arg in "${SCRIPT_ARGS[@]}"; do
    if [[ "$arg" == "--backend" ]]; then
        HAS_BACKEND=true
        break
    fi
done

if [ "$HAS_BACKEND" = false ]; then
    SCRIPT_ARGS+=("--backend" "pytorch")
fi

# Execute the match_start_finder.py with provided arguments
echo "Starting match_start_finder (CUDA enabled)..."
exec python3 florence_extractor/match_start_finder.py "${SCRIPT_ARGS[@]}"