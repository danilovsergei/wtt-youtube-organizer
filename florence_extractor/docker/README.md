# Florence Extractor Docker

Docker container for running `match_start_finder.py` with Intel GPU acceleration via OpenVINO.

## Prerequisites

- Docker and Docker Compose
- Intel GPU with OpenVINO support (integrated or discrete)
- Trained Florence-2 model with OpenVINO conversion (bundled in image)

**Note:** Intel GPU drivers are installed inside the container from Intel's Ubuntu 22.04 APT repository. No host driver installation is required beyond the kernel module (i915).

**Important:** The OpenVINO model (`florence2-tt-finetuned/openvino/`) must exist before building. Run the training and conversion scripts first:
```bash
python train_florence2.py
python convert_to_openvino.py
```

## Build

```bash
cd florence_extractor/docker
./build.sh
```

## Usage

### Recommended: Use matchfinder_cli wrapper

Automatically detects GPU groups and builds/runs the `wtt-stream-match-finder-openvino` image:

```bash
wtt-youtube-organizer matchfinder --output_json=/tmp/matches.json -- --process_all_matches_after 11ZDP_A0Ado
```

## Output

Results are saved to the provided  `/tmp/matches.json` file:
- `/tmp/matches.json` - JSON array with match timestamps and player names

### JSON Format

```json
[
  {
    "timestamp": 494,
    "player1": "PLAYER NAME",
    "player2": "OPPONENT NAME"
  }
]
```

## GPU Configuration

The container uses OpenVINO for Intel GPU acceleration:

- `/dev/dri` is mounted for GPU access
- `wtt-stream-match-finder.sh` auto-detects video/render group IDs from host
- Intel GPU drivers are installed inside the container (from Intel's Ubuntu 22.04 APT repository)
- OpenVINO automatically selects the GPU device

## yt-dlp Updates

The entrypoint script updates yt-dlp to the latest version before every run to ensure compatibility with YouTube's changing API.

## Troubleshooting

### GPU not detected

Ensure your user has access to `/dev/dri`:
```bash
ls -la /dev/dri/
```

### Permission denied

Add your user to the `video` and `render` groups:
```bash
sudo usermod -aG video,render $USER
```

### Model not found

Ensure the Florence-2 model is trained and the OpenVINO version exists:
```bash
ls florence_extractor/florence2-tt-finetuned/openvino/
```

## Updating Docker Dependencies

The Dockerfile pins specific library versions to match the training environment. When you retrain the model with different library versions, update the Dockerfile accordingly.

### Generating requirements.txt with pipreqs

Use `pipreqs` to scan the code and generate requirements with exact versions from your training venv:

```bash
# Install pipreqs if needed
pip install pipreqs

# Generate requirements.txt from florence_extractor code
pipreqs florence_extractor --force

# View generated file
cat florence_extractor/requirements.txt
```

This scans the Python imports and captures the installed versions. Example output:
```
transformers==4.57.6
tokenizers==0.22.2
einops==0.8.2
...
```

### Finding Specific Versions

To check individual packages:

```bash
# Activate the training venv (same one used for train_florence2.py)
source venv/bin/activate

# Get transformers and tokenizers versions
pip show transformers tokenizers | grep -E "^(Name|Version)"
# Output example:
# Name: transformers
# Version: 4.57.6
# Name: tokenizers
# Version: 0.22.2
```

### Updating Dockerfile

Update the pinned versions in `Dockerfile` to match `requirements.txt`:

```dockerfile
RUN pip3 install --no-cache-dir \
    "transformers==4.57.6" \
    "tokenizers==0.22.2" \
    ...
```

**Note:** Some packages from `requirements.txt` should NOT be added to Dockerfile:
- `flash_attn` - Requires CUDA, not needed for OpenVINO (mocked in code)
- `torch` - Installed separately with CPU-only version from PyTorch index
- Multiple opencv versions - Use only `opencv-python-headless`

### OpenVINO Version

The Docker must match your local OpenVINO version:

```bash
# Check local OpenVINO version
pip show openvino | grep Version
# Example: Version: 2025.4.1
```

Update the Dockerfile to match:
1. Base image tag: `openvino/ubuntu22_runtime:2025.4.1`

**Note:** The base image already includes OpenVINO, so no pip install is needed. Only `nncf` is installed separately for model optimization.

### Why This Matters

The model checkpoint saves tokenizer configuration that depends on the specific library version. If Docker uses a different version than training:
- **Newer versions** may have breaking changes to tokenizer attributes
- **Error example:** `RobertaTokenizer has no attribute additional_special_tokens`
- **Fix:** Pin Docker versions to match training venv
