#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# Resolve flutter executable
FLUTTER_BIN="flutter"
if [ -x "/home/geonix/Build/flutter/bin/flutter" ]; then
    FLUTTER_BIN="/home/geonix/Build/flutter/bin/flutter"
fi

# Independent OS Watchdog Timeout (2 minutes max per test phase)
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
echo "🎨 [UI SUITE] Running Flutter Verification"
echo "   (Independent Watchdog Timeout: $WATCHDOG_TIMEOUT)"
echo "=================================================="

run_with_watchdog "🔍 1/3: Analyzing Dart code (lib/)..." $FLUTTER_BIN analyze lib/ --no-fatal-infos

run_with_watchdog "🧪 2/3: Running Unit Tests..." $FLUTTER_BIN test test/unit/

run_with_watchdog "📱 3/3: Running Responsive & Widget Tests..." $FLUTTER_BIN test test/widgets/ test/f5_refresh_test.dart

if [ "$1" == "--e2e" ]; then
    run_with_watchdog "🚀 Running E2E Integration Tests on Linux Desktop..." $FLUTTER_BIN test integration_test/ -d linux
fi

echo "=================================================="
echo "✅ [UI SUITE] All UI verification checks passed!"
echo "=================================================="
