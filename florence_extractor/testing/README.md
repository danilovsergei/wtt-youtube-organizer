# Golden Test Data Generation

This directory contains tools for generating highly accurate "golden" test data from WTT (World Table Tennis) videos. This test data maps every second of a video to its exact scoreboard state, enabling offline, instant unit testing of the `MatchStartFinder` logic without needing to run `yt-dlp`, `ffmpeg`, or local `Florence-2` models.

## `generate_golden_testdata.py`

This script performs two main tasks:
1. **Frame Extraction & Deduplication:** Extracts one frame per second from the given video, applies the standard WTT scoreboard crop, and deduplicates identical consecutive scoreboards to save massive amounts of processing time.
2. **Gemini OCR:** Uses `gemini-2.5-flash-lite` to perform highly accurate OCR on the unique frames and builds a per-second JSON mapping.

### Prerequisites

**1. Gemini API Key (Required)**
The script uses the Gemini API (`gemini-2.5-flash-lite`) to generate the golden data. The script will fail immediately if this is not provided.
You can get a free API key from [Google AI Studio](https://aistudio.google.com/app/apikey).
Once you have it, export it in your terminal:
```bash
export GEMINI_API_KEY="your_api_key_here"
```

**2. Local Environment**
Ensure your virtual environment is activated and dependencies (`google-genai`, `opencv-python-headless`) are installed:
```bash
cd /usr/local/google/home/sdanilov/Build/wtt-youtube-organizer
source venv/bin/activate
pip install google-genai opencv-python-headless tqdm
```

### Usage

#### 1. End-to-End Processing (New Video)
To process a video completely from scratch (extract frames -> deduplicate -> run Gemini OCR -> generate final JSON):

```bash
python florence_extractor/testing/generate_golden_testdata.py \
    --video /path/to/video.webm \
    --output_dir florence_extractor/testing/frames_VideoID \
    --output_file florence_extractor/testing/VideoID_golden.json
```

#### 2. OCR Only (Resume or run on already extracted frames)
If you already extracted the frames (which creates the `mapping.json` and the `unique/` images folder), you can skip the video extraction step and run just the OCR phase. 

The script actively maintains its progress in an `ocr_state.json` file. If the script gets interrupted, encounters an API error, or hits a rate limit, simply run the exact same command again. It will automatically skip the images it has already processed and pick up right where it left off.

```bash
python florence_extractor/testing/generate_golden_testdata.py \
    --only_ocr \
    --output_dir florence_extractor/testing/frames_hJXfBULLDro \
    --output_file florence_extractor/testing/hJXfBULLDro_golden.json
```

### Generated Artifacts
- `frames_VideoID/unique/*.jpg`: The isolated, unique cropped scoreboard images.
- `frames_VideoID/mapping.json`: Maps every `second` (0, 1, 2...) to a `unique/*.jpg` filename.
- `ocr_state.json`: The running progress state of the Gemini OCR process.
- `VideoID_golden.json`: The final combined output file containing the parsed scoreboard JSON payload for every single second of the original video.
