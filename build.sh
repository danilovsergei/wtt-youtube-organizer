#!/bin/sh
set -e
project_dir=$(dirname `realpath "$0"`)
mkdir -p "$project_dir/bin"

# 1. Build Go binary
bin_name="wtt-youtube-organizer"
echo "🐹 Building Go CLI: $bin_name..."
cd "$project_dir/cmd/$bin_name"
go build -ldflags="-s -w" -o "$project_dir/bin/$bin_name"

# 2. Build ytdlp-rookie if cargo is installed
if command -v cargo >/dev/null 2>&1; then
    echo "🦀 Building ytdlp-rookie from tools/ytdlp-rookie..."
    cd "$project_dir/tools/ytdlp-rookie"
    cargo build --release
    cp "$project_dir/tools/ytdlp-rookie/target/release/ytdlp-rookie" "$project_dir/bin/ytdlp-rookie"
    chmod +x "$project_dir/bin/ytdlp-rookie"
    echo "✅ Built bin/ytdlp-rookie"
fi
