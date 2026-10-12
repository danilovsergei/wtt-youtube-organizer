#!/usr/bin/env bash
set -e

# ==============================================================================
# 📺 Android TV Hardware Deployment Script (WTT Organizer)
# ==============================================================================
# Usage:
#   ./deploy_tv.sh [OPTIONS] [DEVICE_IP_OR_SERIAL]
#
# Options:
#   -b, --build       Rebuild the TV release APK before deploying
#   -r, --restart     Force stop app before starting (default: true)
#   -h, --help        Show this help message
#
# Examples:
#   ./deploy_tv.sh                      # Auto-detects connected TV or uses 192.168.31.64:5555
#   ./deploy_tv.sh --build              # Rebuilds and deploys to TV
#   ./deploy_tv.sh 192.168.31.64:5555   # Deploys to specific device IP/port
# ==============================================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK_PATH="${PROJECT_ROOT}/bin/wtt-organizer-tv.apk"
DEFAULT_TV_IP="192.168.31.64:5555"

DO_BUILD=false
DO_RESTART=true
TARGET_DEVICE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -b|--build)
      DO_BUILD=true
      shift
      ;;
    -r|--restart)
      DO_RESTART=true
      shift
      ;;
    -h|--help)
      echo "Usage: ./deploy_tv.sh [-b|--build] [DEVICE_IP]"
      exit 0
      ;;
    *)
      TARGET_DEVICE="$1"
      shift
      ;;
  esac
done

echo "=================================================="
echo "📺 [ANDROID TV DEPLOY] Deploying WTT Organizer"
echo "=================================================="

# 1. Rebuild if requested or if APK does not exist
if [ "$DO_BUILD" = true ] || [ ! -f "$APK_PATH" ]; then
  echo "🔨 Building TV release APK (armeabi-v7a / arm64-v8a)..."
  (cd "${PROJECT_ROOT}/frontend" && ./build_android.sh --tv)
fi

if [ ! -f "$APK_PATH" ]; then
  echo "❌ Error: APK not found at $APK_PATH"
  exit 1
fi

# 2. Determine target device
if [ -z "$TARGET_DEVICE" ]; then
  # Look for connected non-emulator devices in adb
  CONNECTED_TV=$(adb devices | grep -v 'List of' | grep -v 'emulator' | grep -w 'device' | cut -f1 | head -n 1)
  if [ -n "$CONNECTED_TV" ]; then
    TARGET_DEVICE="$CONNECTED_TV"
    echo "🎯 Auto-detected connected TV hardware: $TARGET_DEVICE"
  else
    TARGET_DEVICE="$DEFAULT_TV_IP"
  fi
fi

# Format IP if port was omitted
if [[ "$TARGET_DEVICE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  TARGET_DEVICE="${TARGET_DEVICE}:5555"
fi

# 3. Connect via ADB if it is a network device
if [[ "$TARGET_DEVICE" =~ :5555$ ]]; then
  echo "🔌 Connecting to ADB at $TARGET_DEVICE..."
  adb connect "$TARGET_DEVICE" || true
fi

# Verify connection
if ! adb -s "$TARGET_DEVICE" get-state >/dev/null 2>&1; then
  echo "❌ Error: Could not connect to device $TARGET_DEVICE"
  echo "   Make sure your Android TV / Projector is powered on and ADB debugging is enabled."
  exit 1
fi

DEVICE_MODEL=$(adb -s "$TARGET_DEVICE" shell getprop ro.product.model 2>/dev/null | tr -d r)
DEVICE_ABI=$(adb -s "$TARGET_DEVICE" shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d r)
echo "✅ Target device connected: $TARGET_DEVICE ($DEVICE_MODEL, ABI: $DEVICE_ABI)"

# 4. Install APK
echo "📦 Installing APK ($(du -h "$APK_PATH" | cut -f1))..."
adb -s "$TARGET_DEVICE" install -r "$APK_PATH"

# 5. Launch Application
echo "🚀 Launching WTT Organizer on TV..."
if [ "$DO_RESTART" = true ]; then
  adb -s "$TARGET_DEVICE" shell am force-stop com.example.flutter_app
fi
adb -s "$TARGET_DEVICE" shell am start -n com.example.flutter_app/.MainActivity

echo "=================================================="
echo "🎉 Successfully deployed and launched on $DEVICE_MODEL ($TARGET_DEVICE)!"
echo "=================================================="
