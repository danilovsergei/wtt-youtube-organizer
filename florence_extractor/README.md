# Florence Extractor

Score extraction and match start finder for table tennis videos using Florence-2 OCR.

## Setup

### 1. Train the Model

The repository does not include the trained Florence-2 model. Train it using the provided test data:

```bash
python train_florence2.py
```

This creates `florence2-tt-finetuned/` based on `test_data_sample.csv`.

### 2. (Optional) Create OpenVINO Version

By default, Florence-2 runs on NVIDIA/CUDA or CPU. For Intel GPUs, create an optimized OpenVINO version:

```bash
python convert_to_openvino.py
```

Even an integrated Intel GPU is ~4x faster than CPU!

### 3. (Optional) Verify Model

Run verification against test data:

```bash
python score_extractor.py --images_dir=testdata
```

All images from `testdata/` should pass.

## Usage

### Parse YouTube Video

```bash
python match_start_finder.py --youtube_video "https://www.youtube.com/watch?v=PRYIR0Ays1w"
```

### Parse Local Video

```bash
python match_start_finder.py --local_video "/path/to/video.mp4"
```

### Select Backend

```bash
# OpenVINO (Intel GPU)
python match_start_finder.py --youtube_video "..." --backend openvino

# PyTorch CPU
python match_start_finder.py --youtube_video "..." --backend pytorch-cpu
```

## Preparing Test Data

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
