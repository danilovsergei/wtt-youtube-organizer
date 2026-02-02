#!/bin/bash
sudo docker login
sudo docker tag wtt-stream-match-finder-openvino:latest geonix/wtt-stream-match-finder-openvino:latest
sudo docker push geonix/wtt-stream-match-finder-openvino:latest
