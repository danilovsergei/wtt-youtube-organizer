#!/bin/bash
sudo docker login
sudo docker tag geonix/wtt-stream-match-finder-cuda:latest geonix/wtt-stream-match-finder-cuda:latest
sudo docker push geonix/wtt-stream-match-finder-cuda:latest
