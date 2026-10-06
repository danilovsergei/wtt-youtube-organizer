#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

FLUTTER_BIN="flutter"
if [ -x "/home/geonix/Build/flutter/bin/flutter" ]; then
    FLUTTER_BIN="/home/geonix/Build/flutter/bin/flutter"
fi

WATCHDOG_TIMEOUT="180s"

RECORD=false
REAL_YTDLP=false

for arg in "$@"; do
    case "$arg" in
        --record)
            RECORD=true
            ;;
        --real-ytdlp)
            REAL_YTDLP=true
            ;;
        --all)
            REAL_YTDLP=true
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: ./verify_android.sh [--record] [--real-ytdlp] [--all]"
            exit 1
            ;;
    esac
done

echo "=================================================="
echo "📱 [ANDROID SUITE] Running Pixel 9 Pro XL Verification"
echo "   (Watchdog Timeout: $WATCHDOG_TIMEOUT | Recording: $RECORD)"
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

mkdir -p recordings

run_test_with_recording() {
    local label="$1"
    local test_path="$2"
    local recording_basename="$3"

    echo ""
    echo "$label"

    if [ "$RECORD" = true ]; then
        echo "🎥 [RECORDING] Starting screen capture to recordings/${recording_basename}.mp4..."
        adb shell "rm -f /sdcard/${recording_basename}.mp4"
        nohup adb shell "screenrecord --size 720x1280 /sdcard/${recording_basename}.mp4" >/dev/null 2>&1 &
        sleep 1
    fi

    set +e
    timeout --kill-after=10s "$WATCHDOG_TIMEOUT" $FLUTTER_BIN test "$test_path" -d emulator-5554
    local exit_code=$?
    set -e

    if [ "$RECORD" = true ]; then
        echo "🛑 [RECORDING] Finalizing capture..."
        adb shell "pkill -2 screenrecord" >/dev/null 2>&1 || true
        sleep 3
        adb pull "/sdcard/${recording_basename}.mp4" "recordings/${recording_basename}.mp4" >/dev/null 2>&1 || true
        if [ -f "recordings/${recording_basename}.mp4" ]; then
            local file_size
            file_size=$(ls -lh "recordings/${recording_basename}.mp4" | awk '{print $5}')
            echo "📹 Video saved successfully: recordings/${recording_basename}.mp4 ($file_size)"
        fi
    fi

    if [ $exit_code -ne 0 ]; then
        if [ $exit_code -eq 124 ] || [ $exit_code -eq 137 ]; then
            echo "❌ [TIMEOUT ERROR] Test exceeded $WATCHDOG_TIMEOUT and was killed by OS watchdog!"
        else
            echo "❌ [TEST FAILED] Exit code: $exit_code"
        fi
        exit $exit_code
    fi
}

# 1. Hermetic E2E test on Android
run_test_with_recording \
    "🧪 1. Running Android Hermetic E2E Test (Pixel 9 Pro XL)..." \
    "integration_test/android_hermetic_e2e_test.dart" \
    "android_hermetic_test"

# 2. Real Chaquopy yt-dlp live streaming test if requested
if [ "$REAL_YTDLP" = true ]; then
    run_test_with_recording \
        "🌐 2. Running Android Real Chaquopy yt-dlp Live Stream Test..." \
        "integration_test/android_ytdlp_e2e_test.dart" \
        "android_non_hermetic_real_ytdlp"
fi

echo ""
echo "=================================================="
echo "✅ [ANDROID SUITE] All Android verification checks passed!"
echo "=================================================="
