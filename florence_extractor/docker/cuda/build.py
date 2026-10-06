import subprocess
import os
import shutil
import sys
import argparse
import re


def run(cmd):
    """Runs a shell command and returns the stripped output."""
    return subprocess.check_output(cmd, shell=True, text=True).strip()


def get_gpu_sm():
    """Detects the Compute Capability (SM) of the NVIDIA GPU."""
    try:
        # Queries the GPU for its architecture version (e.g., '120' for Blackwell)
        return run("nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits").replace('.', '')
    except Exception as e:
        print(f"⚠️  Could not detect GPU SM: {e}")
        return None


def build_golden_wheel(sm, wheel_path):
    """The 'Forge': Spawns a CUDA-devel container to compile Flash Attention."""
    torch_arch = f"{sm[0:-1]}.{sm[-1]}"
    print(f"🏗️  [BUILD] Starting Golden Wheel forge for sm_{sm}...")

    # UPDATED: Using 12.8.0-devel to match your 5070 Ti driver/environment
    compile_cmd = (
        f"docker run --rm --gpus all "
        f"-v {os.getcwd()}/local_wheels:/out "
        f"-e TORCH_CUDA_ARCH_LIST='{torch_arch}' "
        f"-e MAX_JOBS=3 "
        f"nvidia/cuda:13.0.0-devel-ubuntu22.04 "
        f"bash -c 'apt update && apt install -y python3-pip python3-dev && "
        f"pip install --upgrade pip setuptools wheel && "
        f"pip install torch packaging ninja --extra-index-url https://download.pytorch.org/whl/cu130 && "
        f"pip wheel flash-attn --no-build-isolation -w /out'"
    )

    try:
        # Using subprocess.run without check_output to let logs stream to stdout
        subprocess.run(compile_cmd, shell=True, check=True)
        # Rename to our standardized PEP-compliant format
        for f in os.listdir("local_wheels"):
            if f.startswith("flash_attn") and "+sm" not in f:
                target = os.path.join(
                    "local_wheels", f"flash_attn-2.8.3+sm{sm}-cp310-cp310-linux_x86_64.whl")
                os.rename(os.path.join("local_wheels", f), target)
                print(f"📦 [SUCCESS] Wheel saved as: {target}")
                break
    except subprocess.CalledProcessError:
        print("❌ [ERROR] Wheel compilation failed!")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Florence Extractor Blackwell Build System")
    parser.add_argument("--build_wheel", action="store_true",
                        help="Force compilation if wheel is missing")
    parser.add_argument("--no-cache", action="store_true",
                        help="Force Docker to rebuild all layers")
    args = parser.parse_args()

    # --- Path Setup ---
    root_dir = os.path.abspath(os.getcwd())
    local_wheels_dir = os.path.join(root_dir, "local_wheels")
    build_context_dir = os.path.join(root_dir, "docker_temp_context")

    sm = get_gpu_sm()
    os.makedirs(local_wheels_dir, exist_ok=True)

    print(f"🔍 [DIAGNOSTIC] Project Root: {root_dir}")
    print(f"🔍 [DIAGNOSTIC] Wheel Directory: {local_wheels_dir}")

    # --- GPU Detection & Wheel Selection ---
    # Force bypass Flash Attention since it fails to compile against PyTorch 2.14 nightlies
    print(f"✅ [INFO] GPU sm_{sm} detected. Bypassing flash-attn in favor of PyTorch native SDPA.")
    flash_required = False
    wheel_source = None

    # --- Staging Area ---
    if os.path.exists(build_context_dir):
        shutil.rmtree(build_context_dir)
    os.makedirs(os.path.join(build_context_dir, "wheels"), exist_ok=True)

    print(f"🚚 [STAGE] Copying local wheels to context...")
    for f in os.listdir(local_wheels_dir):
        if f.endswith(".whl"):
            shutil.copy2(os.path.join(local_wheels_dir, f),
                         os.path.join(build_context_dir, "wheels", f))

    app_src = os.path.join(root_dir, "florence_extractor")
    # Only copy the required checkpoint to save massive amounts of Docker build time and image size
    ignore_patterns = shutil.ignore_patterns(
        "v0-*", "v1-*", "v2-*", "v3-*", "v4-*", "v5-*", "v6-*", "v7-*", "v8-*", "v9-*", "v10-*", "v11-*", "v12-*", "v13-*", "v14-*", "v15-*",
        "checkpoint-500", "checkpoint-1000", "optimizer.pt",
        "testdata", "testdata_hard*", "testdata_enhanced"
    )
    shutil.copytree(app_src, os.path.join(build_context_dir, "florence_extractor"), ignore=ignore_patterns, dirs_exist_ok=True)



    config_src_path = os.path.join(app_src, "docker", "cuda")
    for filename in ['Dockerfile', 'entrypoint.sh']:
        src = os.path.join(config_src_path, filename)
        if os.path.exists(src):
            dest = os.path.join(build_context_dir, filename)
            shutil.copy2(src, dest)
            if filename == 'entrypoint.sh':
                subprocess.run(f"sed -i 's/\\r$//' {dest}", shell=True)

    if os.path.exists(os.path.join(build_context_dir, ".dockerignore")):
        os.remove(os.path.join(build_context_dir, ".dockerignore"))

    # --- Final Docker Build ---
    # UPDATED: Added --progress=plain for verbose terminal output
    cache_flag = "--no-cache" if args.no_cache else ""
    print(
        f"🐳 [DOCKER] Building image (SM={sm}) with {cache_flag if cache_flag else 'cache enabled'}...")

    build_cmd = (
        f"docker build {cache_flag} --progress=plain "
        f"-t geonix/wtt-stream-match-finder-cuda:latest "
        f"--build-arg FLASH_REQUIRED={str(flash_required).lower()} "
        f"--build-arg GPU_SM={sm} "
        f"{build_context_dir}"
    )

    try:
        # Use subprocess.run to allow the user to see the "plain" progress in real-time
        subprocess.run(build_cmd, shell=True, check=True)
        print("🎉 [DONE] Image build complete!")
    except subprocess.CalledProcessError:
        print("❌ [ERROR] Docker image build failed.")
        sys.exit(1)
    finally:
        if os.path.exists(build_context_dir):
            shutil.rmtree(build_context_dir)
            print("🧹 [CLEAN] Temporary build context removed.")


if __name__ == "__main__":
    main()
