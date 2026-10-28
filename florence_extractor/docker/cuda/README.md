# MinerU Extractor - CUDA Docker Environment

This directory contains the Docker configuration for running the MinerU 2.5-Pro (1.2B) Table Tennis score extractor using **NVIDIA GPUs** via CUDA acceleration (with backward-compatible support for Qwen2.5-VL).

## System Prerequisites

To allow Docker to access your host machine's NVIDIA GPU, you must install the **NVIDIA Container Toolkit** on your host system.

### Installing NVIDIA Container Toolkit (Ubuntu/Debian)

1. **Add the NVIDIA package repositories:**
```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
```

2. **Install the toolkit:**
```bash
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
```

3. **Optional Configure Docker and Systemd Cgroups:**
By default, some modern Linux kernels enforce strict `systemd` cgroups isolation which blocks GPU driver passthrough. You must tell the runtime to bypass legacy cgroups.
```bash
sudo sed -i 's/^#no-cgroups = false/no-cgroups = true/;' /etc/nvidia-container-runtime/config.toml
```

4. **Apply to Docker daemon:**
```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

5. **Verify Installation:**
```bash
docker run --rm --gpus all ubuntu nvidia-smi
```
*(If the command above outputs your GPU table, your system is perfectly configured!)*

---

## Building the Image

You can build the image locally using the provided build script:
```bash
# Default: builds MinerU 2.5-Pro image
python3 build.py

# Or explicitly specify model:
python3 build.py --model mineru

# To build legacy Qwen image:
python3 build.py --model qwen
```
This builds and tags the image as `geonix/wtt-stream-match-finder-cuda:mineru` (and `:latest`).

---

## Running the Container

The Go CLI automatically wraps and executes this container when it detects an NVIDIA GPU. However, you can run it manually.

### Example Run Command
```bash
docker run --rm --privileged --gpus all \
  -v /tmp:/output \
  -v ~/.config/wtt-youtube-organizer/cache:/root/.cache/huggingface \
  geonix/wtt-stream-match-finder-cuda:mineru \
  --youtube_video "https://www.youtube.com/watch?v=PRYIR0Ays1w" \
  --output_json_file /output/results.json \
  --cuda_device_id 0
```

### Multi-GPU Systems
If your host machine has multiple GPUs (e.g., a display Quadro and a compute 5070 Ti), you **must** specify the `--cuda_device_id` flag.
