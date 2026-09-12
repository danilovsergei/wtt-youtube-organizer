#!/bin/bash
set -e

echo "🚀 Starting native Gentoo Flutter Linux build..."

# Build the Linux release binary directly on the host OS
flutter clean
flutter pub get
flutter build linux --release

echo ""
echo "✅ Native build complete!"
echo "The executable is compiled specifically for your Gentoo environment."
echo "You can launch it natively by running: ./build/linux/x64/release/bundle/flutter_app"

