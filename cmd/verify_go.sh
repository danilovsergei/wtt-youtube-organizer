#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR/wtt-youtube-organizer/matchfinder_cli"

echo "=================================================="
echo "🐹 [GO CLI SUITE] Running Go Verification"
echo "=================================================="

echo "🔍 1/2: Running go vet..."
go vet ./...

echo "🧪 2/2: Running Go unit tests (Fallback, Queue, Exit Codes)..."
go test -v -skip OpenVINO ./...

echo "=================================================="
echo "✅ [GO CLI SUITE] All Go CLI checks passed!"
echo "=================================================="
