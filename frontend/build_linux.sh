#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "🚀 Starting Native Gentoo Build Environment..."

echo "🧹 Cleaning previous builds..."
flutter clean
flutter pub get

echo "🔨 Compiling raw native binary linked directly to your Gentoo system libraries..."
flutter build linux --release

echo ""
echo "✅ Native compilation complete!"
echo "You can now launch the lightning-fast native application directly by running:"
echo "$DIR/build/linux/x64/release/bundle/flutter_app"

