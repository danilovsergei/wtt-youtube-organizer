#!/bin/bash
set -e

DIR="/home/geonix/Build/wtt-youtube-organizer/frontend"
cd "$DIR"

echo "🔨 Compiling pure Flutter binary via Docker..."
docker run --rm -v "$(pwd)":/app -w /app flutter_linux_builder bash -c "
    git config --global --add safe.directory /app &&
    flutter clean &&
    flutter pub get &&
    flutter build linux --release &&
    chown -R 1000:1000 build/ .dart_tool/ pubspec.lock
"

echo "🔨 Running flatpak-builder using standard io.github.danilovsergei.wtt.json manifest..."
flatpak-builder build-dir io.github.danilovsergei.wtt.json --force-clean --disable-rofiles-fuse --repo=repo

echo "📦 Creating flatpak bundle..."
flatpak build-bundle repo wtt.flatpak io.github.danilovsergei.wtt

echo "✅ Flatpak build complete! Installing locally for verification..."
flatpak uninstall -y io.github.danilovsergei.wtt || true
flatpak install --user -y wtt.flatpak

