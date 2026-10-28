#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

DART_DEFINES=""
if [ -f "$DIR/.env" ]; then
    set -a
    source "$DIR/.env"
    set +a
    if [ -n "$SUPABASE_OAUTH_CLIENT_ID" ]; then
        DART_DEFINES="$DART_DEFINES --dart-define=SUPABASE_OAUTH_CLIENT_ID=$SUPABASE_OAUTH_CLIENT_ID"
    fi
    if [ -n "$SUPABASE_OAUTH_CLIENT_SECRET" ]; then
        DART_DEFINES="$DART_DEFINES --dart-define=SUPABASE_OAUTH_CLIENT_SECRET=$SUPABASE_OAUTH_CLIENT_SECRET"
    fi
fi

echo "🔨 Compiling pure Flutter binary via Docker..."
docker run --rm -v "$(pwd)":/app -w /app flutter_linux_builder bash -c "
    git config --global --add safe.directory /app &&
    flutter clean &&
    flutter pub get &&
    flutter build linux --release $DART_DEFINES &&
    chown -R 1000:1000 /app
"

echo "🔨 Running flatpak-builder using standard io.github.danilovsergei.wtt.json manifest..."
flatpak-builder build-dir io.github.danilovsergei.wtt.json --force-clean --disable-rofiles-fuse --repo=repo

echo "📦 Creating flatpak bundle..."
flatpak build-bundle repo wtt.flatpak io.github.danilovsergei.wtt

echo "✅ Flatpak build complete! Installing locally for verification..."
flatpak uninstall -y io.github.danilovsergei.wtt || true
flatpak install --user -y wtt.flatpak
