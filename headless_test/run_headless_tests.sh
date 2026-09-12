#!/bin/bash
set -e

PLATFORM=$1

if [[ "$PLATFORM" != "linux" && "$PLATFORM" != "web" ]]; then
    echo "========================================="
    echo "❌ Error: Missing or invalid platform."
    echo "Usage: ./run_headless_tests.sh [linux|web]"
    echo "========================================="
    exit 1
fi

echo "Ensuring unified testing Docker image exists..."

if ! docker image inspect wtt_tester >/dev/null 2>&1; then
    echo "Building wtt_tester image with Weston (Wayland) and Google Chrome..."
    cat << 'EOF' > Dockerfile.tester
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    curl git unzip xz-utils zip libglu1-mesa libgtk-3-dev pkg-config clang cmake ninja-build libmpv-dev mpv \
    weston xwayland dbus-x11 wget gnupg \
    && wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | apt-key add - \
    && echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google.list \
    && apt-get update \
    && apt-get install -y google-chrome-stable \
    && wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux -O /usr/local/bin/yt-dlp_linux \
    && chmod a+rx /usr/local/bin/yt-dlp_linux \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/flutter/flutter.git -b stable /flutter
ENV PATH="/flutter/bin:${PATH}"
RUN flutter config --enable-linux-desktop --enable-web
RUN git config --global --add safe.directory /flutter
EOF
    docker build -t wtt_tester -f Dockerfile.tester .
fi

if [ "$PLATFORM" == "linux" ]; then
    echo "========================================="
    echo "🚀 Running Linux Native UI Tests (Headless Weston)"
    echo "========================================="
    cat << 'EOF' > run_linux_test.sh
#!/bin/bash
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p $XDG_RUNTIME_DIR
chmod 0700 $XDG_RUNTIME_DIR

weston --backend=headless-backend.so --socket=wayland-0 --width=1280 --height=720 &
WESTON_PID=$!
sleep 2

export WAYLAND_DISPLAY=wayland-0
export GDK_BACKEND=wayland

cd /app/frontend
git config --global --add safe.directory /app
flutter pub get
flutter test integration_test/app_test.dart -d linux

TEST_EXIT_CODE=$?
kill $WESTON_PID
exit $TEST_EXIT_CODE
EOF
    chmod +x run_linux_test.sh
    docker run --rm --privileged -v "$(pwd)/..:/app" -w /app/headless_test wtt_tester bash run_linux_test.sh
fi

if [ "$PLATFORM" == "web" ]; then
    echo "========================================="
    echo "🚀 Running Web UI Tests (Headless Chrome)"
    echo "========================================="
    cat << 'EOF' > run_web_test.sh
#!/bin/bash
cd /app/frontend
git config --global --add safe.directory /app
flutter pub get
flutter test integration_test/app_test.dart -d web-server --browser-name=chrome
EOF
    chmod +x run_web_test.sh
    docker run --rm -v "$(pwd)/..:/app" -w /app/headless_test wtt_tester bash run_web_test.sh
fi

