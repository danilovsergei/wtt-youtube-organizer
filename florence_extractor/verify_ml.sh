#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "=================================================="
echo "🤖 [ML EXTRACTOR SUITE] Running ML Verification"
echo "=================================================="

# Use qwen_venv python if available, otherwise python3
PY_BIN="python3"
if [ -x "/home/geonix/Build/wtt-youtube-organizer/qwen_venv/bin/python3" ]; then
    PY_BIN="/home/geonix/Build/wtt-youtube-organizer/qwen_venv/bin/python3"
fi

echo "🧪 Running unit tests (match_start_finder, processor, force_matches)..."
$PY_BIN -m unittest prod_video_processor_test.py
$PY_BIN -m unittest match_start_finder_test.py

echo "=================================================="
echo "✅ [ML EXTRACTOR SUITE] All ML unit tests passed!"
echo "=================================================="
