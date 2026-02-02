#!/bin/bash
# Build the Florence Extractor Docker image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building wtt-stream-match-finder-openvino Docker image..."
docker-compose build

echo ""
echo "Build complete!"
echo ""
echo "Usage:"
echo "OUTPUT_DIR=/tmp ./run.sh \\"
echo "  --youtube_video "https://www.youtube.com/watch?v=PRYIR0Ays1w" \\"
echo "  --output_json_file /output/results.json"
