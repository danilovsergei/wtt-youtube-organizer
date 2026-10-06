#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

WATCHDOG_TIMEOUT="120s"

run_with_watchdog() {
    local label="$1"
    shift
    echo "$label"
    if ! timeout --kill-after=10s "$WATCHDOG_TIMEOUT" "$@"; then
        local exit_code=$?
        if [ $exit_code -eq 124 ] || [ $exit_code -eq 137 ]; then
            echo ""
            echo "❌ [TIMEOUT ERROR] Command exceeded $WATCHDOG_TIMEOUT limit and was killed by the independent OS watchdog!"
            echo "   Terminated command: $*"
            echo ""
        fi
        exit $exit_code
    fi
}

echo "=================================================="
echo "🤖 [ML EXTRACTOR SUITE] Running ML Verification"
echo "   (Independent Watchdog Timeout: $WATCHDOG_TIMEOUT)"
echo "=================================================="

PY_BIN="python3"
if [ -x "/home/geonix/Build/wtt-youtube-organizer/qwen_venv/bin/python3" ]; then
    PY_BIN="/home/geonix/Build/wtt-youtube-organizer/qwen_venv/bin/python3"
fi

run_with_watchdog "🧪 Running unit tests (match_start_finder, processor)..." $PY_BIN -m unittest prod_video_processor_test.py match_start_finder_test.py

echo "=================================================="
echo "✅ [ML EXTRACTOR SUITE] All ML unit tests passed!"
echo "=================================================="
