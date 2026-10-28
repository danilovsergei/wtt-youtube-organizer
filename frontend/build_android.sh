#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

FLUTTER_BIN="flutter"
if [ -x "/home/geonix/Build/flutter/bin/flutter" ]; then
    FLUTTER_BIN="/home/geonix/Build/flutter/bin/flutter"
fi

ROOT_DIR="$(dirname "$DIR")"
TARGET_ABI=""
BUILD_TYPE="release"
DO_INSTALL=false
OUTPUT_NAME="wtt-organizer-release.apk"

for arg in "$@"; do
    case "$arg" in
        --pixel9|--arm64)
            TARGET_ABI="android-arm64"
            OUTPUT_NAME="wtt-organizer-pixel9.apk"
            ;;
        --tv|--android-tv)
            TARGET_ABI="android-arm,android-arm64"
            OUTPUT_NAME="wtt-organizer-tv.apk"
            ;;
        --tv-universal)
            TARGET_ABI=""
            OUTPUT_NAME="wtt-organizer-tv.apk"
            ;;
        --x64|--emulator)
            TARGET_ABI="android-x64"
            OUTPUT_NAME="wtt-organizer-emulator.apk"
            ;;
        --debug)
            BUILD_TYPE="debug"
            OUTPUT_NAME="wtt-organizer.apk"
            ;;
        --install)
            DO_INSTALL=true
            ;;
        *)
            echo "Usage: ./build_android.sh [--tv] [--pixel9] [--universal] [--debug] [--install]"
            exit 1
            ;;
    esac
done

"$DIR/download_mpv_v41.sh"

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
echo "🤖 [ANDROID BUILD] Building WTT Organizer APK"
echo "   Mode: $BUILD_TYPE | ABI: ${TARGET_ABI:-universal} | Target: $OUTPUT_NAME"
echo "=================================================="

BUILD_ARGS=()
if [ "$BUILD_TYPE" = "release" ]; then
    BUILD_ARGS+=("apk" "--release")
else
    BUILD_ARGS+=("apk" "--debug")
fi

if [ -n "$TARGET_ABI" ]; then
    BUILD_ARGS+=("--target-platform" "$TARGET_ABI")
fi

if [ -f "$DIR/.env" ]; then
    set -a
    source "$DIR/.env"
    set +a
    if [ -n "$SUPABASE_OAUTH_CLIENT_ID" ]; then
        BUILD_ARGS+=("--dart-define=SUPABASE_OAUTH_CLIENT_ID=$SUPABASE_OAUTH_CLIENT_ID")
    fi
    if [ -n "$SUPABASE_OAUTH_CLIENT_SECRET" ]; then
        BUILD_ARGS+=("--dart-define=SUPABASE_OAUTH_CLIENT_SECRET=$SUPABASE_OAUTH_CLIENT_SECRET")
    fi
fi

"$FLUTTER_BIN" build "${BUILD_ARGS[@]}"

# Copy output artifact to bin/
mkdir -p "$ROOT_DIR/bin"
if [ "$BUILD_TYPE" = "release" ]; then
    SOURCE_APK="$DIR/build/app/outputs/flutter-apk/app-release.apk"
else
    SOURCE_APK="$DIR/build/app/outputs/flutter-apk/app-debug.apk"
fi

DEST_APK="$ROOT_DIR/bin/$OUTPUT_NAME"
cp "$SOURCE_APK" "$DEST_APK"

# If building for TV or Release, also maintain default wtt-organizer-release.apk
if [ "$OUTPUT_NAME" = "wtt-organizer-tv.apk" ]; then
    cp "$SOURCE_APK" "$ROOT_DIR/bin/wtt-organizer-tv-11.apk"
fi

echo ""
echo "✅ Build completed successfully!"
ls -lh "$DEST_APK"

if [ "$DO_INSTALL" = true ]; then
    echo ""
    echo "📲 Installing APK to connected device..."
    adb install -r "$DEST_APK"
    echo "✅ Installed successfully!"
fi
