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


try:
    from google import genai
    from google.genai import types
except ImportError:
    print("Error: google-genai is not installed. Please run: pip install google-genai")
    sys.exit(1)

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
    if not os.path.exists(mapping_file):
        print(f"Error: Mapping file not found: {mapping_file}")
        sys.exit(1)

    with open(mapping_file, "r") as f:
        mapping = json.load(f)

    unique_frames = sorted(list(set(mapping.values())))
    
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
    
    Examine the provided image carefully. A valid WTT scoreboard ALWAYS has exactly TWO distinct rows. Each row MUST contain BOTH a player name AND a score.

    CRITICAL RULES:
    1. Do NOT hallucinate or guess names from blurry shapes.
    2. If the image is just a blurry background, arena lights, or people, return the empty format.
    3. You MUST detect BOTH player names AND their scores. If only one player is visible, or if the text is partially obscured/missing, return the empty format.
    
    The empty format is strictly:
    {
      "player1": "",
      "player2": "",
      "p1_sets": 0,
      "p2_sets": 0,
      "p1_points": 0,
      "p2_points": 0
    }

    Only if you clearly see two full rows (both player names and both scores are fully visible and legible), format the output strictly as JSON with this structure:
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

        try:
            myfile = client.files.upload(file=img_path)
            response = client.models.generate_content(
                model='gemini-3.1-flash-lite-preview',
                contents=[myfile, prompt],
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
            
        except Exception as e:
            print(f"Error processing {frame_name}: {e}")
            break # Stop on API error so user can resume later

    generate_final_output(mapping, results, output_file)

def generate_final_output(mapping: dict, results: dict, output_file: str):
    """Combine mapping and OCR results into the final per-second output."""
    final_output = {}
    for sec, frame_name in mapping.items():
        if frame_name in results:
            final_output[sec] = results[frame_name]

    with open(output_file, "w") as f:
        json.dump(final_output, f, indent=2)
    print(f"Final output saved to {output_file}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", type=str, help="Path to input video")
    parser.add_argument("--output_dir", type=str, default="frames", help="Directory to store extracted frames")
    parser.add_argument("--only_ocr", action="store_true", help="Skip extraction and only run OCR")
    parser.add_argument("--output_file", type=str, default="golden_scoreboards.json", help="Final output file")
    
    args = parser.parse_args()

    if not os.environ.get("GEMINI_API_KEY"):
        print("ERROR: GEMINI_API_KEY environment variable is missing!")
        print("Please set it before running this script: export GEMINI_API_KEY='your_api_key'")
        sys.exit(1)

    if not args.only_ocr:
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
        
    run_ocr(mapping_file, unique_dir, args.output_file)

