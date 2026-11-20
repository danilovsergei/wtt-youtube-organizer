#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$DIR/.." && pwd )"

WATCHDOG_TIMEOUT="180s"

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
echo "🐹 [GO SUITE] Running Full Go & WTT Verification"
echo "   (Independent Watchdog Timeout: $WATCHDOG_TIMEOUT)"
echo "=================================================="

cd "$REPO_ROOT"

run_with_watchdog "🔍 1/4: Running go vet across all packages..." go vet ./cmd/... ./wtt_api/... ./db/importer/...

run_with_watchdog "🧪 2/4: Running Matchfinder CLI tests..." go test -v -skip OpenVINO ./cmd/wtt-youtube-organizer/matchfinder_cli/...

run_with_watchdog "🧪 3/4: Running WTT API & Matcher tests..." go test -v ./wtt_api/...

run_with_watchdog "🧪 4/4: Running Hermetic WTT Integration & Importer tests..." go test -v -run TestHermeticWTTBackendIntegration ./db/importer/...

echo "=================================================="
echo "✅ [GO SUITE] All Go CLI, WTT API & Hermetic tests passed!"
echo "=================================================="
