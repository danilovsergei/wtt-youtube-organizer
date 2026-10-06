#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# Resolve flutter executable
FLUTTER_BIN="flutter"
if [ -x "/home/geonix/Build/flutter/bin/flutter" ]; then
    FLUTTER_BIN="/home/geonix/Build/flutter/bin/flutter"
fi

echo "=================================================="
echo "🎨 [UI SUITE] Running Flutter Verification"
echo "=================================================="

echo "🔍 1/3: Analyzing Dart code (lib/)..."
$FLUTTER_BIN analyze lib/ --no-fatal-infos

echo "🧪 2/3: Running Unit Tests..."
$FLUTTER_BIN test test/unit/

echo "📱 3/3: Running Responsive & Widget Tests..."
$FLUTTER_BIN test test/widgets/ test/f5_refresh_test.dart

if [ "$1" == "--e2e" ]; then
    echo "🚀 Running E2E Integration Tests..."
    $FLUTTER_BIN test integration_test/ -d linux
fi

echo "=================================================="
echo "✅ [UI SUITE] All UI verification checks passed!"
echo "=================================================="
