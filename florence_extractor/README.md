# Florence Extractor

Score extraction and match start finder for table tennis videos using Florence-2 OCR.

## Usage

### Option A: Docker Container (Recommended)

Pre-built Docker image with Intel GPU support via OpenVINO and pretrained model embedded.
No local setup required!

**Using wrapper script:**
```bash
cd florence_extractor/docker

OUTPUT_DIR=/tmp ./wtt-stream-match-finder.sh \
    --youtube_video "https://www.youtube.com/watch?v=PRYIR0Ays1w" \
    --output_json_file /output/results.json
```

The script automatically:
- Pulls the image from Docker Hub if not present
- Detects video/render group IDs for GPU access
- Mounts the output directory

**Requirements:**
- Intel GPU (integrated or discrete) with OpenVINO support
- User must be in `video` and `render` groups: `sudo usermod -aG video,render $USER`

**Output:**
Results are saved to the mounted directory (`/tmp/matches/results.json`):
```json
[
  {"timestamp": 720, "player1": "MA LONG", "player2": "FAN ZHENDONG"},
  {"timestamp": 4140, "player1": "CHEN MENG", "player2": "SUN YINGSHA"}
]
```

### Option B: Run with Python development environment
Running without a docker will require to generate trained florence2 model using instructions below

### Perform developer setup
#### 1. Setup python venv
Use florence_extractor/docker/Dockerfile file for reference which pip packages versions to install
#### 2. Train the Model

The repository does not include the trained Florence-2 model. Train it using the provided test data:

```bash
python train_florence2.py
```

This creates `florence2-tt-finetuned/` based on `test_data_sample.csv`.

#### 3. (Optional) Create OpenVINO Version

By default, Florence-2 runs on NVIDIA/CUDA or CPU. For Intel GPUs, create an optimized OpenVINO version:

```bash
python convert_to_openvino.py
```

Even an integrated Intel GPU is ~4x faster than CPU!

#### 4. (Optional) Verify Model

Run verification against test data:

```bash
python score_extractor.py --images_dir=testdata
```

All images from `testdata/` should pass.

#### Parse YouTube Video

```bash
python match_start_finder.py --youtube_video "https://www.youtube.com/watch?v=PRYIR0Ays1w"
```

#### Parse Local Video
add fake `video_id` and `video_title` if you are not planning to save results in the database

```bash
python match_start_finder.py --local_video "/path/to/video.mp4" \
    --video_id "i8OS-w44mrQ" \
    --video_title "WTT Star Contender Bangkok 2026 Day 1"
```

#### Select Backend

```bash
# OpenVINO (Intel GPU)
python match_start_finder.py --youtube_video "..." --backend openvino

# PyTorch CPU
python match_start_finder.py --youtube_video "..." --backend pytorch-cpu
```

## Add new Test Data to Retrain the model

### 1. Get Cropped Images

Run with `--keep_cropped` to save cropped score images:

```bash
python match_start_finder.py --youtube_video "https://..." --keep_cropped
```

Cropped images are saved to `match_starts/cropped_frames/` with unique UUIDs.

### 2. Update Test Data

1. Move images from `match_starts/cropped_frames/` to `testdata/`
2. Update `test_data_sample.csv` with expected values

### 3. Retrain Model

```bash
python train_florence2.py

# If using OpenVINO:
python convert_to_openvino.py
```

## Directory Structure

```
florence_extractor/
├── match_start_finder.py    # Main video parser
├── score_extractor.py       # Score extraction utilities
├── train_florence2.py       # Model training script
├── convert_to_openvino.py   # OpenVINO conversion
├── test_data_sample.csv     # Training/test data
├── testdata/                # Test images
├── cropped_images/          # Temporary cropped images
├── florence2-tt-finetuned/  # Trained model
│   └── openvino/            # OpenVINO converted model
└── backends/                # Inference backends
    ├── base.py
    ├── pytorch_backend.py
    └── openvino_backend.py
```
