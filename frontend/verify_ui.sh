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

echo "🛡️ Verifying stream playback architectural constraints..."
if grep -rn -E -- "('-4'|'--force-ipv4')" lib/video/; then
    echo "❌ REGRESSION: Found prohibited forced IPv4 flag in lib/video/! This breaks dual-stack networks with HTTP 403 Forbidden."
    exit 1
fi

run_with_watchdog "🔍 1/4: Analyzing Dart code (lib/)..." $FLUTTER_BIN analyze lib/ --no-fatal-infos

run_with_watchdog "🧪 2/4: Running Unit Tests..." $FLUTTER_BIN test test/unit/

run_with_watchdog "📱 3/4: Running Responsive & Widget Tests..." $FLUTTER_BIN test test/widgets/ test/f5_refresh_test.dart

if [ "$1" != "--no-e2e" ]; then
    export PATH="/usr/lib/llvm/22/bin:$PATH"
    export DISPLAY="${DISPLAY:-:0}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
    run_with_watchdog "🚀 4/5: Running Hermetic E2E Desktop Test (App Boot, Match Click, Seeking, Video Playback)..." $FLUTTER_BIN test integration_test/hermetic_e2e_test.dart -d linux
    run_with_watchdog "⚡ 5/6: Running Paginated Loading E2E Desktop Test (Infinite Scroll, On-Demand Matches)..." $FLUTTER_BIN test integration_test/paginated_loading_e2e_test.dart -d linux
    run_with_watchdog "🛑 6/7: Running Extraction Error Overlay E2E Desktop Test..." $FLUTTER_BIN test integration_test/extraction_error_e2e_test.dart -d linux
    run_with_watchdog "⏯️  7/8: Running Playback Progress Save/Resume E2E Desktop Test..." $FLUTTER_BIN test integration_test/playback_progress_e2e_test.dart -d linux
    run_with_watchdog "☁️  8/10: Running Cloud Sync Two-Way Reconciliation E2E Desktop Test..." $FLUTTER_BIN test integration_test/cloud_sync_e2e_test.dart -d linux
    run_with_watchdog "⏸️  9/10: Running Supabase Paused Detection & Keep-Alive E2E Desktop Test..." $FLUTTER_BIN test integration_test/supabase_keepalive_paused_e2e_test.dart -d linux
    run_with_watchdog "🔗 10/10: Running Device Pairing & Facilitated Cloud Sync E2E Desktop Test..." $FLUTTER_BIN test integration_test/device_pairing_e2e_test.dart -d linux
fi

echo "=================================================="
echo "✅ [UI SUITE] All UI verification checks passed!"
echo "=================================================="
