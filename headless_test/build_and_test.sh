#!/bin/bash
set -e

cd /home/geonix/Build/wtt-youtube-organizer/headless_test
echo "Running Linux Native E2E Test in Weston..." > status.log

cat << 'EOF' > run_test_in_docker.sh
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
flutter pub get
flutter test integration_test/app_test.dart -d linux

kill $WESTON_PID
chown -R 1000:1000 /app
EOF
chmod +x run_test_in_docker.sh

docker run --rm \
  --privileged \
  -v /home/geonix/Build/wtt-youtube-organizer:/app \
  -w /app/headless_test \
  flutter_tester \
  bash run_test_in_docker.sh > build.log 2>&1

echo "Finished" > status.log

