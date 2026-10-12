#!/bin/bash
set -euo pipefail

JNI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android/app/src/main/jniLibs"

if [ -f "$JNI_DIR/arm64-v8a/libmpv.so" ] && [ -f "$JNI_DIR/armeabi-v7a/libmpv.so" ]; then
    echo "✅ MPV v0.41 libraries already present in $JNI_DIR"
    exit 0
fi

echo "📦 Downloading and extracting MPV v0.41 native libraries..."
python3 - << 'PYEOF'
import urllib.request, zipfile, io, os

target_dir = os.environ.get('JNI_DIR')
abis = ['armeabi-v7a', 'arm64-v8a', 'x86_64']

for abi in abis:
    abi_dir = os.path.join(target_dir, abi)
    os.makedirs(abi_dir, exist_ok=True)
    url = f'https://github.com/mpv-android/mpv-android/releases/download/2026-09-17/app-default-{abi}-release.apk'
    print(f'Downloading {abi} from {url}...')
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req) as resp:
        data = resp.read()
    z = zipfile.ZipFile(io.BytesIO(data))
    for name in z.namelist():
        if name.startswith(f'lib/{abi}/') and name.endswith('.so'):
            so_name = os.path.basename(name)
            out_path = os.path.join(abi_dir, so_name)
            with open(out_path, 'wb') as f:
                f.write(z.read(name))
    
    # Also fetch helper
    helper_url = f'https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.11/default-{abi}.jar'
    req_h = urllib.request.Request(helper_url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req_h) as resp:
        data_h = resp.read()
    zh = zipfile.ZipFile(io.BytesIO(data_h))
    for name in zh.namelist():
        if 'libmediakitandroidhelper.so' in name:
            out_path = os.path.join(abi_dir, 'libmediakitandroidhelper.so')
            with open(out_path, 'wb') as f:
                f.write(zh.read(name))

print('MPV v0.41 native libraries extracted successfully!')
# Patch AImageReader max_images from 3 to 10 to prevent MediaTek VPU buffer queue starvation
# while staying safely below the MediaTek 16-buffer hardware VPU ceiling (avoids GraphicBuffer ENOMEM)
print("Applying MediaTek buffer tuning fix (max_images = 32)...")
p_arm = os.path.join(target_dir, "armeabi-v7a/libmpv.so")
with open(p_arm, "r+b") as f:
    f.seek(0x318998)
    f.write(bytes.fromhex("2000a0e3"))
    print("  Patched armeabi-v7a libmpv.so (max_images = 32)")

p_arm64 = os.path.join(target_dir, "arm64-v8a/libmpv.so")
with open(p_arm64, "r+b") as f:
    f.seek(0x401928)
    f.write(bytes.fromhex("04048052"))
    print("  Patched arm64-v8a libmpv.so (max_images = 32)")

p_x86 = os.path.join(target_dir, "x86_64/libmpv.so")
with open(p_x86, "r+b") as f:
    f.seek(0x3fd58d)
    f.write(bytes.fromhex("41b820000000"))
    print("  Patched x86_64 libmpv.so (max_images = 32)")

PYEOF
chmod +x "$JNI_DIR"/*/*.so 2>/dev/null || true
echo "✅ MPV v0.41 setup complete!"
