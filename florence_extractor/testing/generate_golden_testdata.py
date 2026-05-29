import argparse
import cv2
import os
import json
import numpy as np
from tqdm import tqdm
import sys
import time

# Add parent directory to path to import ProdWttVideoProcessor
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from prod_video_processor import ProdWttVideoProcessor

# Cropping constants from our established logic
BOTTOM_PERCENT = 0.14
LEFT_PERCENT = 0.40
DIFF_THRESHOLD = 3.0



def process_video(video_path: str, output_dir: str):
    """Extract frames and create the unique mapping."""
    os.makedirs(output_dir, exist_ok=True)
    unique_dir = os.path.join(output_dir, "unique")
    os.makedirs(unique_dir, exist_ok=True)

    import subprocess
    import tempfile
    
    # Use ffprobe to get exact duration
    cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', video_path]
    try:
        duration_sec = int(float(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()))
    except Exception as e:
        print(f"Failed to get video duration: {e}")
        sys.exit(1)

    print(f"Video duration: {duration_sec} seconds")

    mapping = {}
    last_unique_gray = None
    last_unique_filename = None
    unique_count = 0

    print("Extracting frames via system FFmpeg (AV1 Supported)...")
    
    with tempfile.TemporaryDirectory() as temp_dir:
        # Extract strictly at 1 fps directly via ffmpeg, which handles AV1 natively
        subprocess.run([
            'ffmpeg', '-y', '-v', 'error', 
            '-i', video_path, 
            '-r', '1', 
            '-q:v', '2', 
            os.path.join(temp_dir, 'raw_frame_%05d.jpg')
        ], check=True)
        
        # Deduplicate the extracted frames
        print("Deduplicating frames...")
        for sec in tqdm(range(duration_sec)):
            frame_path = os.path.join(temp_dir, f"raw_frame_{sec+1:05d}.jpg")
            if not os.path.exists(frame_path):
                break
                
            frame = cv2.imread(frame_path)
            h, w = frame.shape[:2]
            crop_h = int(h * BOTTOM_PERCENT)
            crop_w = int(w * LEFT_PERCENT)
            
            cropped = frame[h - crop_h:h, 0:crop_w]
            gray = cv2.cvtColor(cropped, cv2.COLOR_BGR2GRAY)
            
            is_new = False
            if last_unique_gray is None:
                is_new = True
            else:
                diff = cv2.absdiff(gray, last_unique_gray)
                if np.mean(diff) > DIFF_THRESHOLD:
                    is_new = True
                    
            if is_new:
                last_unique_gray = gray
                last_unique_filename = f"frame_{sec:05d}.jpg"
                cv2.imwrite(os.path.join(unique_dir, last_unique_filename), cropped)
                unique_count += 1
                
            mapping[str(sec)] = last_unique_filename

    mapping_file = os.path.join(output_dir, "mapping.json")
    with open(mapping_file, "w") as f:
        json.dump(mapping, f, indent=2)


    print(f"Extraction complete! Found {unique_count} unique frames.")
    if unique_count == 0:
        print("ERROR: No frames were extracted! The video might be corrupt, encoded in an unsupported format (like AV1), or completely blank.")
        sys.exit(1)
        
    return mapping_file, unique_dir


def run_ocr(mapping_file: str, unique_dir: str, output_file: str):
    """Run Gemini OCR on unique frames and map back to seconds."""
    if mapping_file and os.path.exists(mapping_file):
        with open(mapping_file, "r") as f:
            mapping = json.load(f)
        unique_frames = sorted(list(set(mapping.values())))
    else:
        import glob
        mapping = None
        unique_frames = sorted([os.path.basename(p) for p in glob.glob(os.path.join(unique_dir, "*.jpg"))])
    
    # Initialize state
    state_file = os.path.join(os.path.dirname(output_file), "ocr_state.json")
    results = {}
    if os.path.exists(state_file):
        with open(state_file, "r") as f:
            results = json.load(f)

    # Filter queue
    queue = [f for f in unique_frames if f not in results]
    print(f"Total unique frames: {len(unique_frames)}")
    print(f"Remaining to process: {len(queue)}")

    if not queue:
        print("All frames already processed!")
        generate_final_output(mapping, results, output_file)
        return

    # Setup Gemini
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("Error: GEMINI_API_KEY environment variable is not set.")
        sys.exit(1)
        
    client = genai.Client(api_key=api_key)

    prompt = """
    You are an expert OCR system specializing in World Table Tennis (WTT) scoreboards.
    
    Examine the provided image carefully. A valid WTT LIVE IN-GAME scoreboard ALWAYS has exactly TWO distinct rows for the current matchup. Each row MUST contain BOTH a player name AND two numbers: their sets won AND their current points.

    CRITICAL RULES:
    1. Do NOT hallucinate or guess names from blurry shapes.
    2. If the image is just a blurry background, arena lights, or people, return the empty format.
    3. REJECT TOURNAMENT BRACKETS AND PATHS. If the image shows a tournament bracket, player path, or summary (often with multiple matchups, connecting lines, arrows, or names severely truncated to an initial, and only showing one number per player representing sets won), return the empty format.
    4. You MUST detect BOTH player names AND both scores (sets AND points). If only one score number is visible per player, it is NOT a live scoreboard.
    
    The empty format is strictly:
    {
      "player1": "",
      "player2": "",
      "p1_sets": 0,
      "p2_sets": 0,
      "p1_points": 0,
      "p2_points": 0
    }

    Only if you clearly see two full rows (both player names and both sets and points are fully visible and legible for a single match), format the output strictly as JSON with this structure:
    {
      "player1": "NAME 1",
      "player2": "NAME 2",
      "p1_sets": 0,
      "p2_sets": 0,
      "p1_points": 0,
      "p2_points": 0
    }
    """

    print("Starting Gemini OCR...")
    for frame_name in tqdm(queue):
        img_path = os.path.join(unique_dir, frame_name)
        if not os.path.exists(img_path):
            continue

        retries = 5
        success = False
        while retries > 0 and not success:
            try:
                from PIL import Image
                img = Image.open(img_path)
                
                response = client.models.generate_content(
                    model='gemini-3.1-flash-lite',
                    contents=[img, prompt],
                    config=types.GenerateContentConfig(
                        response_mime_type="application/json",
                        temperature=0.0
                    )
                )
                
                try:
                    data = json.loads(response.text)
                    results[frame_name] = data
                except json.JSONDecodeError:
                    results[frame_name] = {}
                
                # Save state frequently
                with open(state_file, "w") as f:
                    json.dump(results, f, indent=2)
                    
                # Avoid aggressive rate limiting just in case
                time.sleep(0.5)
                success = True
                
            except Exception as e:
                err_str = str(e).lower()
                if any(err in err_str for err in ["429", "too many requests", "503", "quota", "104", "connection", "timeout", "broken pipe"]):
                    wait_time = (6 - retries) * 10
                    print(f"\nNetwork/API error hit. Waiting {wait_time}s before retry... ({retries} retries left) - {e}")
                    time.sleep(wait_time)
                    retries -= 1
                else:
                    print(f"\nError processing {frame_name}: {e}")
                    break # Stop on non-retryable API error

        if not success:
            print(f"Failed to process {frame_name} after retries or due to fatal error. Stopping.")
            break

    generate_final_output(mapping, results, output_file)

def generate_final_output(mapping: dict, results: dict, output_file: str):
    """Combine mapping and OCR results into the final per-second output."""
    if mapping is not None:
        final_output = {}
        for sec, frame_name in mapping.items():
            if frame_name in results:
                final_output[sec] = results[frame_name]
    else:
        final_output = results

    with open(output_file, "w") as f:
        json.dump(final_output, f, indent=2)
    print(f"Final output saved to {output_file}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", type=str, help="Path to input video")
    parser.add_argument("--output_dir", type=str, default="frames", help="Directory to store extracted frames")
    parser.add_argument("--only_ocr", action="store_true", help="Skip extraction and only run OCR")
    parser.add_argument("--image_dir", type=str, help="Directory containing raw images to OCR directly (ignores video/mapping)")
    parser.add_argument("--output_file", type=str, default="golden_scoreboards.json", help="Final output file")
    parser.add_argument("--just_frames", action="store_true", help="Only extract frames and exit (no OCR)")
    parser.add_argument("--append_csv", type=str, help="Path to test_data_sample.csv to automatically append these frames as new training data")
    parser.add_argument("--override_p1", type=str, help="Strictly override player 1's expected name in the CSV (e.g. 'FEGERL LOUIS')")
    parser.add_argument("--override_p2", type=str, help="Strictly override player 2's expected name in the CSV (e.g. 'DIMITRIJ OVTCHAROV')")
    
    args = parser.parse_args()

    if args.image_dir:
        mapping_file = None
        unique_dir = args.image_dir
    elif not args.only_ocr:
        if not args.video:
            print("Error: --video is required unless --only_ocr is specified")
            sys.exit(1)
            
        video_target = args.video
        if "youtube.com" in video_target or "youtu.be" in video_target or not os.path.exists(video_target):
            print(f"Using ProdWttVideoProcessor to download {video_target}...")
            processor = ProdWttVideoProcessor()
            video_target = processor.download_video(video_target, args.output_dir)
            if not video_target or not os.path.exists(video_target):
                print(f"Error: Failed to download video {args.video}")
                sys.exit(1)
                
        mapping_file, unique_dir = process_video(video_target, args.output_dir)
    else:
        mapping_file = os.path.join(args.output_dir, "mapping.json")
        unique_dir = os.path.join(args.output_dir, "unique")

    if args.just_frames:
        print(f"\nFrames successfully extracted to {unique_dir}")
        print("Exiting without running OCR as requested by --just_frames.")
        sys.exit(0)

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        print("Error: google-genai is not installed. Please run: pip install google-genai")
        sys.exit(1)
    run_ocr(mapping_file, unique_dir, args.output_file)

    if args.append_csv:
        import pandas as pd
        import shutil
        import uuid
        
        csv_path = args.append_csv
        if not os.path.exists(csv_path):
            print(f"Error: CSV not found at {csv_path}")
            sys.exit(1)
            
        df = pd.read_csv(csv_path)
        testdata_dir = os.path.join(os.path.dirname(csv_path), "testdata")
        os.makedirs(testdata_dir, exist_ok=True)
        
        with open(args.output_file, "r") as f:
            ocr_results = json.load(f)
            
        new_rows = []
        for frame_name, data in ocr_results.items():
            if not data: continue
            
            p1 = args.override_p1 if args.override_p1 else data.get("player1", "")
            p2 = args.override_p2 if args.override_p2 else data.get("player2", "")
            s1 = data.get("p1_sets", 0)
            g1 = data.get("p1_points", 0)
            s2 = data.get("p2_sets", 0)
            g2 = data.get("p2_points", 0)
            
            img_source_path = os.path.join(unique_dir, frame_name)
            if not os.path.exists(img_source_path):
                continue
                
            new_filename = f"cropped_{uuid.uuid4().hex[:8]}.jpg"
            new_filepath = os.path.join(testdata_dir, new_filename)
            shutil.copy(img_source_path, new_filepath)
            
            new_rows.append({
                "image path": f"testdata/{new_filename}",
                "row 1 expected player": p1,
                "row 2 expected player 2": p2,
                "row 1 set score": s1,
                "row 1 game score": g1,
                "row 2 set score": s2,
                "row 2 game score": g2
            })
            
        if new_rows:
            new_df = pd.DataFrame(new_rows)
            df = pd.concat([df, new_df], ignore_index=True)
            df.to_csv(csv_path, index=False)
            print(f"\nSuccessfully copied images and appended {len(new_rows)} new rows to {csv_path}!")
            print(f"Total dataset size is now {len(df)}.")
        else:
            print("\nNo valid OCR data found to append.")

