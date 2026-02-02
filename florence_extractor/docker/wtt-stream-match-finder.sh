#!/bin/bash
# Wrapper script to run match-finder with automatic GPU group detection
#
# Usage:
#   ./run.sh --youtube_video "https://..." --output_json_file /output/results.json
#
# Optional environment variables:
#   OUTPUT_DIR - host directory to mount for output (default: ./output)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="wtt-stream-match-finder-openvino"

# Check if image exists, build if not
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Image '$IMAGE_NAME' not found. Building..."
    docker-compose build
    echo ""
fi

# Detect GPU group IDs from host system
VIDEO_GID=$(getent group video 2>/dev/null | cut -d: -f3 || echo "44")
RENDER_GID=$(getent group render 2>/dev/null | cut -d: -f3 || echo "")

echo "Detected GPU groups:"
echo "  video GID: ${VIDEO_GID}"
echo "  render GID: ${RENDER_GID:-not found}"

# Build group_add arguments
GROUP_ARGS="--group-add ${VIDEO_GID}"
if [ -n "${RENDER_GID}" ]; then
    GROUP_ARGS="${GROUP_ARGS} --group-add ${RENDER_GID}"
fi

# Intel GPU libraries are installed inside the container
# from Intel's Ubuntu 22.04 APT repository
echo "Intel GPU: Using container's built-in drivers"

# Default output directory
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
mkdir -p "${OUTPUT_DIR}"

echo "Output directory: ${OUTPUT_DIR}"
echo ""

# Run the container with GPU access
# NOTE: Use container's own Level Zero libraries (base image includes them)
# Don't mount host libraries - they may have GLIBC version mismatch
docker run --rm \
    --device /dev/dri:/dev/dri \
    ${GROUP_ARGS} \
    -v "${OUTPUT_DIR}:/output" \
    "$IMAGE_NAME" \
    "$@"

# Show host path for output files
OUTPUT_JSON=""
for arg in "$@"; do
    if [[ "$prev_arg" == "--output_json_file" ]]; then
        OUTPUT_JSON="${arg#/output/}"
    fi
    prev_arg="$arg"
done

if [ -n "$OUTPUT_JSON" ] && [ -f "${OUTPUT_DIR}/${OUTPUT_JSON}" ]; then
    echo "Matches details saved to: ${OUTPUT_DIR}/${OUTPUT_JSON}" 
fi
