#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

FLUTTER_BIN="flutter"
if [ -x "/home/geonix/Build/flutter/bin/flutter" ]; then
    FLUTTER_BIN="/home/geonix/Build/flutter/bin/flutter"
fi

WATCHDOG_TIMEOUT="180s"

echo "=================================================="
echo "📺 [ANDROID TV SUITE] Running Android TV 1080p Verification"
echo "   (Watchdog Timeout: $WATCHDOG_TIMEOUT)"
echo "=================================================="

TV_PORT=5556
TV_SERIAL="emulator-$TV_PORT"

# Ensure TV emulator is booted
if ! adb devices | grep -q "$TV_SERIAL"; then
    echo "Starting Android_TV_1080p emulator on port $TV_PORT in background..."
    nohup emulator -avd Android_TV_1080p -port $TV_PORT -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect > /tmp/emulator_tv.log 2>&1 &
    adb -s $TV_SERIAL wait-for-device shell "while [[ \$(getprop sys.boot_completed) != 1 ]]; do sleep 2; done"
    echo "✅ Android TV 1080p emulator booted!"
fi

# Push test video fixture to emulator
adb -s $TV_SERIAL push test/assets/test_video.mp4 /data/local/tmp/test_video.mp4 >/dev/null 2>&1

echo ""
echo "🧪 Running Android TV Hermetic E2E Test ($TV_SERIAL)..."
timeout --kill-after=10s "$WATCHDOG_TIMEOUT" "$FLUTTER_BIN" test integration_test/android_hermetic_e2e_test.dart -d "$TV_SERIAL"

echo ""
echo "=================================================="
echo "✅ [ANDROID TV SUITE] All Android TV verification checks passed!"
echo "=================================================="
