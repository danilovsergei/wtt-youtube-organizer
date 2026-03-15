#!/bin/bash
set -e

echo "==========================================="
echo "          Running Go Test Suite            "
echo "==========================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Discover and run all Go tests across the entire repository
go test -v ./...

echo ""
echo "✅ All Go Tests Passed!"
