#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

FLUTTER_BIN="flutter"
if [ -x "/home/geonix/Build/flutter/bin/flutter" ]; then
    FLUTTER_BIN="/home/geonix/Build/flutter/bin/flutter"
fi

# Detect running Android TV or Phone emulator
DEVICE=$(adb devices | grep -E "emulator-[0-9]+" | awk '{print $1}' | tail -n 1)

if [ -z "$DEVICE" ]; then
    echo "⚠️ No running Android emulator found. Attempting to start Android_TV_1080p..."
    /home/geonix/Android/sdk/emulator/emulator -avd Android_TV_1080p -no-window -no-audio -no-boot-anim -gpu swiftshader &
    adb wait-for-device
    DEVICE=$(adb devices | grep -E "emulator-[0-9]+" | awk '{print $1}' | tail -n 1)
fi

# Enforce InitializerIsolate on Android to prevent Dart FFI trampoline crash on 32-bit ARM (XGIMI TV)
python3 - << 'PYEOF'
import glob
for p in glob.glob("/home/geonix/.pub-cache/hosted/pub.dev/media_kit-*/lib/src/player/native/core/execmem_restriction.dart"):
    with open(p) as f:
        src = f.read()
    if "Platform.isAndroid) return true;" not in src:
        src = src.replace("bool _checkIfExecmemRestricted() {\n  if (Platform.isLinux || Platform.isAndroid) {", "bool _checkIfExecmemRestricted() {\n  if (Platform.isAndroid) return true;\n  if (Platform.isLinux || Platform.isAndroid) {")
        with open(p, "w") as f:
            f.write(src)
PYEOF

echo "=================================================="
/home/geonix/Android/sdk/platform-tools/adb -s "$DEVICE" push /home/geonix/Build/wtt-youtube-organizer/frontend/test/assets/test_video.mp4 /data/local/tmp/test_video.mp4 2>/dev/null || true
/home/geonix/Android/sdk/platform-tools/adb -s "$DEVICE" push /home/geonix/Build/wtt-youtube-organizer/frontend/test/assets/test_audio1.mp4 /data/local/tmp/test_audio1.mp4 2>/dev/null || true
/home/geonix/Android/sdk/platform-tools/adb -s "$DEVICE" push /home/geonix/Build/wtt-youtube-organizer/frontend/test/assets/test_audio2.mp4 /data/local/tmp/test_audio2.mp4 2>/dev/null || true
echo "🤖 [ANDROID VM] Running Hermetic E2E Test on $DEVICE"
echo "=================================================="

$FLUTTER_BIN test integration_test/hermetic_e2e_test.dart -d "$DEVICE" --timeout=120s

echo "⚡ [ANDROID VM] Running Paginated Loading E2E Test on $DEVICE"
$FLUTTER_BIN test integration_test/paginated_loading_e2e_test.dart -d "$DEVICE" --timeout=120s

echo "🛑 [ANDROID VM] Running Extraction Error Overlay E2E Test on $DEVICE"
$FLUTTER_BIN test integration_test/extraction_error_e2e_test.dart -d "$DEVICE" --timeout=120s

echo "⏯️ [ANDROID VM] Running Playback Progress Save/Resume E2E Test on $DEVICE"
$FLUTTER_BIN test integration_test/playback_progress_e2e_test.dart -d "$DEVICE" --timeout=120s

echo "=================================================="
echo "✅ [ANDROID VM] Hermetic verification passed on Android VM!"
echo "=================================================="
