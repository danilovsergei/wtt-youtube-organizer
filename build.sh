#!/bin/sh
project_dir=$(dirname `realpath "$0"`)
timestamp=$(date -d "@$(date +%s)" +"%y-%m-%d")

bin_name="wtt-youtube-organizer"
cd "$project_dir/cmd/$bin_name"
go build -ldflags="-s -w" -o "$project_dir/bin/$bin_name"