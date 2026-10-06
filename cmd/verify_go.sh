#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR/wtt-youtube-organizer/matchfinder_cli"

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
echo "🐹 [GO CLI SUITE] Running Go Verification"
echo "   (Independent Watchdog Timeout: $WATCHDOG_TIMEOUT)"
echo "=================================================="

run_with_watchdog "🔍 1/2: Running go vet..." go vet ./...

run_with_watchdog "🧪 2/2: Running Go unit tests..." go test -v -skip OpenVINO ./...

echo "=================================================="
echo "✅ [GO CLI SUITE] All Go CLI checks passed!"
echo "=================================================="
