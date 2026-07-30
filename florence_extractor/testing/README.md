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

#### 3. Extract Frames Only (`--just_frames`)
If you want to mine training data for edge cases (e.g., specific players) without spending API calls on Gemini OCR, you can extract the unique scoreboard frames and exit immediately:

```bash
python florence_extractor/testing/generate_golden_testdata.py \
    --video "https://www.youtube.com/watch?v=VIDEO_ID_HERE" \
    --output_dir /home/geonix/frames_ovtcharov \
    --just_frames
```

#### 4. Run OCR on a Custom Image Folder (`--image_dir`)
If you manually curated a folder of specific cropped images (from the step above) and want to generate golden data *only* for those images without needing a video or `mapping.json`, use the `--image_dir` flag:

```bash
python florence_extractor/testing/generate_golden_testdata.py \
    --image_dir /home/geonix/frames_ovtcharov/unique \
    --output_file /home/geonix/frames_ovtcharov/ovtcharov_scoreboard.json
```


#### 5. Automatically Append OCR Results to Training Dataset (`--append_csv`)
If you want to use the OCR results to fine-tune the Florence-2 model, you can automatically copy the processed images into your `testdata` folder, assign them unique UUID filenames, and strictly append the scores into your `test_data_sample.csv`. 
You can also use `--override_p1` and `--override_p2` to hardcode the exact player names in the ground-truth data, preventing Gemini from accidentally injecting typos.

```bash
python florence_extractor/testing/generate_golden_testdata.py \
    --image_dir /home/geonix/frames_ovtcharov/unique \
    --output_file /home/geonix/frames_ovtcharov/ovtcharov_scoreboard.json \
    --append_csv florence_extractor/test_data_sample.csv \
    --override_p1 "SOME OPPONENT" \
    --override_p2 "DIMITRIJ OVTCHAROV"
```

### Generated Artifacts
- `frames_VideoID/unique/*.jpg`: The isolated, unique cropped scoreboard images.
- `frames_VideoID/mapping.json`: Maps every `second` (0, 1, 2...) to a `unique/*.jpg` filename.
- `ocr_state.json`: The running progress state of the Gemini OCR process.
- `VideoID_golden.json`: The final combined output file containing the parsed scoreboard JSON payload for every single second of the original video.

## `mine_new_players.py` (Automated Active Learning)

This script automates the discovery and mining of new training data to make the Florence-2 model infinitely scalable. It queries the production database for matches played in the last `X` days, identifies players who are underrepresented in the `test_data_sample.csv` (e.g., they have fewer than 10 images), and automatically downloads their matches.

To ensure pristine training data, it uses Florence-2 to actively scan the video at the exact start offset of the match, extracts highly distinct scoreboards using mathematical deduplication (ensuring no two identical scores are mined), and feeds those unique frames directly into the Gemini OCR pipeline (`generate_golden_testdata.py`) to organically append them to your CSV.

### Usage (Gemini Batch API Pipeline)

Because image processing at scale can be expensive, this script is fully integrated with the **asynchronous Gemini Batch API**, which cuts processing costs by exactly 50%.

Because the Batch API is asynchronous, running the pipeline is a two-step process:

#### Step 1: Submit the Batch Job (Daily)
When you run the script normally, it extracts all the necessary frames, uploads them to Google's Cloud Storage (File API), bundles them into a single massive Batch Job, submits it to Google, and exits immediately.

```bash
# Default: Scan last 7 days, 10 frames per player
LD_PRELOAD= python florence_extractor/testing/mine_new_players.py

# Retroactive: Scan last 30 days, 15 frames per player
LD_PRELOAD= python florence_extractor/testing/mine_new_players.py --days 30 --target_frames 15
```
*(Note: `LD_PRELOAD=` is required because this script boots up the local PyTorch Florence-2 model for semantic frame deduplication before uploading them to Gemini).*

#### Step 2: Poll for Results (Every 5 minutes)
Batch jobs enter a low-priority queue on Google's servers. It may take anywhere from 5 minutes to 2 hours for Google to process the images. 
You must use the `--poll_for_images` flag to check the status of active batch jobs. When a job succeeds, the script will automatically download the JSONL results, parse them, copy the images to your `testdata/` folder, and securely append the ground-truth scores directly into your `test_data_sample.csv`.

```bash
# Run this via a cron job every 5 minutes
python florence_extractor/testing/mine_new_players.py --poll_for_images
```

#### Utility Commands
**Audit the database without downloading (Dry Run)**
Use the `--list_players` flag to quickly check which players are underrepresented and how many frames the script *would* mine, without actually executing any downloads.
```bash
python florence_extractor/testing/mine_new_players.py --list_players
```

**Extract frames locally without calling Gemini**
If you want to extract the deduplicated frames to your local drive to verify the Florence-2 extraction quality without burning any Gemini API tokens or altering your CSV:
```bash
LD_PRELOAD= python florence_extractor/testing/mine_new_players.py --extract_frames
```
*Frames will be permanently saved to `~/.config/wtt-youtube-organizer/mined_frames/PLAYER_NAME/unique`.*

**Submit local frames to Gemini Batch API**
If you previously used `--extract_frames` to generate a local `mined_frames` folder and now want to process them, use the `--submit_local_frames` flag. It will upload the deduplicated images to the Gemini File API and submit a single Batch Job without redownloading any videos.
```bash
python florence_extractor/testing/mine_new_players.py --submit_local_frames
```

**Run OCR synchronously (Real-Time API)**
If you want to bypass the asynchronous Batch API and run the extraction immediately, you can use the `--realtime` flag. This will call the Gemini API synchronously and instantly append the results to your CSV. Note that real-time processing costs approximately double the Batch API price.
By default, this uses `gemini-1.5-flash`. You can optionally specify a different model using the `--model` flag.
```bash
LD_PRELOAD= python florence_extractor/testing/mine_new_players.py --realtime --model "gemini-3.6-flash-lite"
```
