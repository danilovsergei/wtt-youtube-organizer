#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

FLUTTER_BIN="flutter"
if [ -x "/home/geonix/Build/flutter/bin/flutter" ]; then
    FLUTTER_BIN="/home/geonix/Build/flutter/bin/flutter"
fi

WATCHDOG_TIMEOUT="180s"

run_with_watchdog() {
    local label="$1"
    shift
    echo "$label"
    if ! timeout --kill-after=10s "$WATCHDOG_TIMEOUT" "$@"; then
        local exit_code=$?
        if [ $exit_code -eq 124 ] || [ $exit_code -eq 137 ]; then
            echo ""
            echo "❌ [TIMEOUT ERROR] Command exceeded $WATCHDOG_TIMEOUT limit and was killed by independent OS watchdog!"
            echo "   Command: $*"
            echo ""
        fi
        exit $exit_code
    fi
}

echo "=================================================="
echo "📱 [ANDROID SUITE] Running Pixel 9 Pro XL Verification"
echo "   (Independent Watchdog Timeout: $WATCHDOG_TIMEOUT)"
echo "=================================================="

# Ensure emulator is booted
if ! adb devices | grep -q "emulator-"; then
    echo "Starting Pixel_9_Pro_XL emulator in background..."
    nohup emulator -avd Pixel_9_Pro_XL -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect > /tmp/emulator.log 2>&1 &
    adb wait-for-device shell "while [[ \$(getprop sys.boot_completed) != 1 ]]; do sleep 2; done"
    echo "Emulator booted!"
fi

# Ensure hermetic test video is on device
adb push test/assets/test_video.mp4 /data/local/tmp/test_video.mp4 >/dev/null 2>&1
adb shell chmod 666 /data/local/tmp/test_video.mp4

# Run Hermetic E2E test on Android
run_with_watchdog "🧪 Running Android Hermetic E2E Test (Pixel 9 Pro XL)..." \
    $FLUTTER_BIN test integration_test/android_hermetic_e2e_test.dart -d emulator-5554

# Run real yt-dlp test if requested
if [ "$1" == "--real-ytdlp" ]; then
    run_with_watchdog "🌐 Running Android Real Chaquopy yt-dlp Live Stream Test..." \
        $FLUTTER_BIN test integration_test/android_ytdlp_e2e_test.dart -d emulator-5554
fi

echo "=================================================="
echo "✅ [ANDROID SUITE] All Android verification checks passed!"
echo "=================================================="
