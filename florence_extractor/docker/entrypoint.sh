#!/bin/bash
set -e

# Save arguments before sourcing setupvars.sh (which may modify $@)
SCRIPT_ARGS=("$@")

# Set up OpenVINO environment (from base image)
if [ -f /opt/intel/openvino/setupvars.sh ]; then
    source /opt/intel/openvino/setupvars.sh
fi

# Update yt-dlp to the latest version before every run
# This ensures compatibility with latest YouTube changes
echo "Updating yt-dlp to the latest version..."
pip install --no-cache-dir -U yt-dlp

# Pre-download yt-dlp remote components for JS challenge solving (Deno)
echo "Downloading yt-dlp remote components..."
yt-dlp --remote-components ejs:github --version 2>&1 || echo "Warning: Failed to pre-download remote components"
echo "Deno version: $(deno --version 2>&1 | head -1)"

# Debug: Check OpenVINO availability and GPU libraries
echo ""
echo "=== OpenVINO Debug ==="
echo "DRI devices:"
ls -la /dev/dri/ 2>/dev/null || echo "  No /dev/dri found"
echo ""
echo "Level Zero libraries:"
ls -la /usr/lib/x86_64-linux-gnu/libze*.so* 2>/dev/null || echo "  No libze found in /usr/lib"
echo ""
echo "Intel OpenCL:"
ls -la /usr/lib/x86_64-linux-gnu/intel-opencl/ 2>/dev/null || echo "  No intel-opencl found"
cat /etc/OpenCL/vendors/intel.icd 2>/dev/null || echo "  No intel.icd found"
echo ""
python3 -c "
import sys
try:
    import openvino as ov
    print(f'OpenVINO version: {ov.__version__}')
    from openvino import Core
    core = Core()
    devices = core.available_devices
    print(f'Available devices: {devices}')
    for dev in devices:
        print(f'  {dev}: {core.get_property(dev, \"FULL_DEVICE_NAME\")}')
except ImportError as e:
    print(f'OpenVINO import failed: {e}')
except Exception as e:
    print(f'OpenVINO error: {e}')
"
echo "======================"
echo ""

# Execute the match_start_finder.py with provided arguments
echo "Starting match_start_finder..."
exec python3 florence_extractor/match_start_finder.py "${SCRIPT_ARGS[@]}"
