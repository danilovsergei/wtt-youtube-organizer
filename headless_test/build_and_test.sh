#!/bin/bash
set -e

cd /home/geonix/Build/wtt-youtube-organizer/headless_test
echo "Running Linux Native E2E Test in Weston..." > status.log

cat << 'EOF' > run_test_in_docker.sh
#!/bin/bash

# Copy the host application to an ephemeral container directory to ensure zero side-effects on the host filesystem
cp -a /host_app /app
cd /app/frontend

export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p $XDG_RUNTIME_DIR
chmod 0700 $XDG_RUNTIME_DIR

weston --backend=headless-backend.so --socket=wayland-0 --width=1280 --height=720 &
WESTON_PID=$!
sleep 2

export WAYLAND_DISPLAY=wayland-0
export GDK_BACKEND=wayland

flutter pub get
flutter test integration_test/app_test.dart -d linux

kill $WESTON_PID
EOF
chmod +x run_test_in_docker.sh

docker run --rm \
  --privileged \
  -v /home/geonix/Build/wtt-youtube-organizer:/host_app:ro \
  -w /tmp \
  flutter_tester \
  bash /host_app/headless_test/run_test_in_docker.sh > build.log 2>&1

echo "Finished" > status.log

