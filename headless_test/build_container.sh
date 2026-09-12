#!/bin/bash
cd /home/geonix/Build/wtt-youtube-organizer/headless_test
docker build -t flutter_linux_builder -f Dockerfile.linux . > docker_build.log 2>&1
echo "Finished" > status.log

