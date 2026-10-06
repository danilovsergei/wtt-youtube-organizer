# Qwen Scoreboard Extractor

Score extraction and match start finder for table tennis broadcast streams using fine-tuned **Qwen2.5-VL-3B** Vision-Language Model with LoRA adapters.

## Architecture & Overview

The extractor leverages **Qwen2.5-VL-3B-Instruct** fine-tuned on curated WTT broadcast frames:
* **Token-1 Early Escape Hatch:** On empty tables, crowd shots, or player celebrations, the model immediately outputs an empty JSON object `{}` within 2 tokens (~15 ms), preventing hallucinations.
* **Character-Pipe Transcriptions:** Player names are transcribed with character pipe delimiters (e.g. `K|U|A|I | M|A|N`) to eliminate language-model spelling hallucinations on foreign names.
* **Optical Conditioning Pipeline:** 
  1. Luminance CLAHE dynamically expands contrast on washed-out graphics.
  2. 2.0x horizontal anamorphic stretch expands compressed character glyphs across visual patches.
  3. 28px patch-grid alignment (height 112, width multiple of 28) matches Qwen's Vision Transformer (ViT) patch structure.

## Usage

### Option A: Docker Container (Recommended)

Pre-built Docker image with NVIDIA GPU acceleration via CUDA:

```bash
cd florence_extractor/docker/cuda
python3 build.py
```

The Go CLI (`wtt-youtube-organizer matchfinder`) automatically runs this container with:
- `--gpus all` access
- Mapped HuggingFace model cache (`~/.config/wtt-youtube-organizer/cache:/root/.cache/huggingface`)
- Embedded fine-tuned LoRA weights (`adapter_model.safetensors`)

### Option B: Local Python Environment

#### 1. Setup Virtual Environment
```bash
python3 -m venv qwen_venv
source qwen_venv/bin/activate
pip install torch torchvision transformers peft qwen-vl-utils opencv-python-headless yt-dlp
```

#### 2. Train / Fine-Tune Qwen LoRA
```bash
./train_qwen.sh
```
This automatically:
1. Prepares `qwen_train.json` and `qwen_val.json` from `test_data_sample.csv` (using grouped 85/15 train/val split).
2. Runs LoRA SFT training using Swift/Transformers in `bfloat16`.
3. Outputs checkpoints to `output/qwen2.5-vl-3b-wtt-lora/`.

#### 3. Parse YouTube Video
```bash
python3 match_start_finder.py --youtube_video "https://www.youtube.com/watch?v=PRYIR0Ays1w"
```

#### 4. Parse Local Video
```bash
python3 match_start_finder.py --local_video "/path/to/video.mp4" \
    --video_id "i8OS-w44mrQ" \
    --video_title "WTT Star Contender Bangkok 2026 Day 1"
```

## Hermetic Testing (No ML / No Video Downloads)

To instantly test changes to the match-finding logic (binary search, gap ignoring, phase transitions) without the heavy overhead of downloading videos or running Qwen / PyTorch, use the hermetic testing mode with a pre-extracted "golden dataset":

```bash
python match_start_finder.py \
    --youtube_video hJXfBULLDro \
    --test_golden_dataset testing/frames_hJXfBULLDro/hJXfBULLDro_golden.json \
    --output_json_file hermetic_output.json
```

### Running Unit Tests

```bash
cd florence_extractor

# Run processor tests
python -m unittest prod_video_processor_test.py

# Run match finder tests
python -m unittest match_start_finder_test.py
```

## Add New Training Data

### 1. Extract & Augment Empty Frames
```bash
python3 add_empty_frames.py /path/to/empty_crops/
```

### 2. Targeted Golden Frame Mining
```bash
python florence_extractor/testing/generate_golden_testdata.py \
    --video "https://www.youtube.com/watch?v=VIDEO_ID" \
    --output_dir /tmp/frames_matchup \
    --append_csv florence_extractor/test_data_sample.csv \
    --target_p1 "SOME OPPONENT" \
    --target_p2 "OVTCHAROV" \
    --override_p1 "SOME OPPONENT" \
    --override_p2 "DIMITRIJ OVTCHAROV" \
    --max_append 15
```

## Directory Structure

```
florence_extractor/
├── match_start_finder.py       # Main video parser and match finder
├── prod_video_processor.py     # Production Qwen2.5-VL scoreboard processor
├── prepare_qwen_dataset.py     # Dataset formatting & prompt builder
├── train_qwen.sh               # LoRA fine-tuning training script
├── add_empty_frames.py         # Negative sample ingestion & enhancement
├── test_data_sample.csv        # Golden dataset catalog
├── testdata/                   # Golden crop images (positives & negatives)
├── output/                     # Saved Qwen LoRA checkpoints
└── docker/
    └── cuda/                   # Production CUDA Docker image & build script
```
