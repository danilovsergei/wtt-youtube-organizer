#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "🚀 Bootstrapping Native Gentoo Build Environment..."

# Automatically provision an isolated, native Flutter SDK to bypass the Ubuntu Docker ABI collision
if [ ! -d "$DIR/flutter_sdk" ]; then
    echo "Downloading native Linux Flutter SDK..."
    git clone https://github.com/flutter/flutter.git -b stable "$DIR/flutter_sdk"
    "$DIR/flutter_sdk/bin/flutter" config --enable-linux-desktop
fi

export PATH="$DIR/flutter_sdk/bin:$PATH"

# Flutter strictly hardcodes 'clang++' execution, entirely ignoring standard CXX environment variables.
# We create a local shim to maliciously masquerade GCC as Clang to force Flutter to compile without the llvm toolchain!
echo "🎭 Injecting Clang-to-GCC compiler shims..."
ln -sf $(which g++) "$DIR/flutter_sdk/bin/clang++"
ln -sf $(which gcc) "$DIR/flutter_sdk/bin/clang"

echo "🧹 Cleaning previous builds..."
flutter clean
flutter pub get

echo "🔨 Compiling raw native binary linked directly to your Gentoo system libraries using GCC..."
flutter build linux --release

echo ""
echo "✅ Native compilation complete!"
echo "You can now launch the lightning-fast native application directly by running:"
echo "$DIR/build/linux/x64/release/bundle/flutter_app"

