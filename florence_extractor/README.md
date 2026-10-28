# MinerU Scoreboard Extractor

Score extraction and match start finder for table tennis broadcast streams using fine-tuned **MinerU 2.5-Pro (1.2B)** Vision-Language Model with LoRA adapters (with backwards-compatible support for Qwen2.5-VL-3B).

## Architecture & Overview

The production extractor leverages **opendatalab/MinerU2.5-Pro-2605-1.2B** fine-tuned on curated WTT broadcast frames:
* **Lightweight & High Efficiency:** 1.2B parameters requiring only **~2.6 GB VRAM** during inference (allowing 3–4 parallel stream workers on an RTX 5070 Ti).
* **Early Null-Branch Escape Hatch:** On empty tables, crowd shots, or player celebrations, the model immediately outputs an empty JSON object `{}` within 2 tokens (~15 ms), preventing hallucinations.
* **Character-Pipe Transcriptions:** Player names are transcribed with character pipe delimiters (e.g. `W|E|N| |R|U|I|B|O`) to eliminate language-model spelling autocorrect on foreign names.
* **Optical Conditioning Pipeline:** 
  1. Luminance CLAHE dynamically expands contrast on washed-out graphics.
  2. 2.0x horizontal anamorphic stretch expands compressed character glyphs across visual patches.
  3. 28px patch-grid alignment (height 112, width multiple of 28) matches Vision Transformer (ViT) patch structure.

## Usage

### Option A: Docker Container (Recommended)

Pre-built Docker image with NVIDIA GPU acceleration via CUDA:

```bash
cd florence_extractor/docker/cuda
python3 build.py --model mineru
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

#### 2. Train / Fine-Tune MinerU LoRA
```bash
./train_mineru.sh
# or: python3 train_mineru.py
```
This automatically:
1. Prepares JSON datasets from `test_data_sample.csv` (using grouped 85/15 train/val split).
2. Runs LoRA SFT training using ms-swift in `bfloat16`.
3. Outputs checkpoints to `output/mineru2.5-pro-1.2b-wtt-lora/`.

*(To train legacy Qwen2.5-VL instead, run `./train_qwen.sh`).*

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

To instantly test changes to the match-finding logic (binary search, gap ignoring, phase transitions) without downloading videos or running PyTorch, use the hermetic testing mode with a pre-extracted "golden dataset":

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
├── prod_video_processor.py     # Production MinerU / Qwen scoreboard processor
├── prepare_qwen_dataset.py     # Dataset formatting & prompt builder
├── train_mineru.sh             # MinerU LoRA fine-tuning training script
├── train_mineru.py             # MinerU Python training launcher
├── train_qwen.sh               # Legacy Qwen LoRA fine-tuning script
├── add_empty_frames.py         # Negative sample ingestion & enhancement
├── test_data_sample.csv        # Golden dataset catalog
├── testdata/                   # Golden crop images (positives & negatives)
├── output/                     # Saved LoRA checkpoints (mineru & qwen)
└── docker/
    └── cuda/                   # Production CUDA Docker image & build script
```
