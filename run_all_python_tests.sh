#!/bin/bash
set -e

echo "==========================================="
echo "        Running Python Test Suite          "
echo "==========================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
else
    echo "Error: Python virtual environment 'venv' not found in the project root."
    exit 1
fi

cd florence_extractor
# Discover and run all unit tests in the florence_extractor directory
python -m unittest discover -p "*_test.py" -v

echo ""
echo "✅ All Python Tests Passed!"
