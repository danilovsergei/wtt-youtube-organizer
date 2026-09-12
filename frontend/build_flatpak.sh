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
    chown -R \$(id -u):\$(id -g) build/ .dart_tool/ pubspec.lock
"

 > io.github.danilovsergei.wtt.json
{
    "app-id": "io.github.danilovsergei.wtt",
    "runtime": "org.kde.Platform",
    "runtime-version": "6.11",
    "sdk": "org.kde.Sdk",
    "command": "wtt",
    "finish-args": [
        "--share=network",
        "--socket=fallback-x11",
        "--socket=wayland",
        "--socket=pulseaudio",
        "--device=dri",
        "--share=ipc"
    ],
    "modules": [
        {
            "name": "luajit",
            "buildsystem": "simple",
            "build-commands": ["make PREFIX=/app", "make install PREFIX=/app"],
            "sources": [{"type": "git", "url": "https://github.com/openresty/luajit2.git", "tag": "v2.1-20260620", "commit": "b411bec3ce550ef9968fc83bca094455cf812c1f"}]
        },
        {
            "name": "ffmpeg",
            "buildsystem": "autotools",
            "config-opts": ["--enable-shared", "--disable-static", "--disable-programs", "--disable-doc", "--disable-debug", "--enable-gpl", "--enable-version3", "--enable-gnutls"],
            "sources": [{"type": "archive", "url": "https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz", "sha256": "7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52"}]
        },
        {
            "name": "libass",
            "buildsystem": "autotools",
            "config-opts": ["--disable-static"],
            "sources": [{"type": "archive", "url": "https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.gz", "sha256": "caab4b993dd7be6187c55623b789ed75dddefea6e65938af134637c732fe094a"}]
        },
        {
            "name": "libplacebo",
            "buildsystem": "meson",
            "config-opts": ["-Ddemos=false"],
            "sources": [{"type": "git", "url": "https://github.com/haasn/libplacebo.git", "tag": "v7.360.1", "commit": "cee9b076f2c63104ccfd497fa79c39a867293ec4"}]
        },
        {
            "name": "libmpv",
            "buildsystem": "meson",
            "config-opts": ["-Dlibmpv=true", "-Dcplayer=false", "-Dalsa=disabled", "-Dhtml-build=disabled", "-Djavascript=disabled", "-Duchardet=disabled", "-Dlibarchive=disabled"],
            "sources": [{"type": "archive", "url": "https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz", "sha256": "ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"}]
        },
        {
            "name": "wtt",
            "buildsystem": "simple",
            "build-commands": [
                "mkdir -p /app/bin /app/wtt",
                "cp -r bundle/* /app/wtt/",
                "ln -s /app/lib/libmpv.so /app/wtt/lib/libmpv.so.1",
                "echo '#!/bin/bash' > /app/bin/wtt",
                "echo 'export LD_LIBRARY_PATH=/app/lib:/app/wtt/lib:$LD_LIBRARY_PATH' >> /app/bin/wtt",
                "echo 'exec /app/wtt/flutter_app \"$@\"' >> /app/bin/wtt",
                "chmod +x /app/bin/wtt"
            ],
            "sources": [
                {
                    "type": "dir",
                    "path": "build/linux/x64/release/bundle",
                    "dest": "bundle"
                }
            ]
        }
    ]
}
JSON


echo "🔨 Running flatpak-builder..."
flatpak-builder build-dir io.github.danilovsergei.wtt.json --force-clean --disable-rofiles-fuse --repo=repo

echo "📦 Creating flatpak bundle..."
flatpak build-bundle repo wtt.flatpak io.github.danilovsergei.wtt

echo "✅ Flatpak build complete! Installing locally for verification..."
flatpak uninstall -y io.github.danilovsergei.wtt || true
flatpak install --user -y wtt.flatpak

