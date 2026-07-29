import os
import sys
import argparse
import psycopg2
import pandas as pd
import subprocess
import tempfile
import cv2
import numpy as np

DATABASE_URL = "<DATABASE_URL_REDACTED>"
BOTTOM_PERCENT = 0.14
LEFT_PERCENT = 0.40
DIFF_THRESHOLD = 3.0

# Add parent directory to path to import ProdWttVideoProcessor
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from prod_video_processor import ProdWttVideoProcessor

def get_recent_matches(days):
    conn = psycopg2.connect(DATABASE_URL)
    cursor = conn.cursor()
    query = f"""
    SELECT m.video_offset_seconds, v.youtube_id, p.name 
    FROM matches m
    JOIN videos v ON m.video_id = v.id
    JOIN match_participants mp ON m.id = mp.match_id
    JOIN players p ON mp.player_id = p.id
    WHERE v.upload_date >= NOW() - INTERVAL '{days} days'
    """
    cursor.execute(query)
    results = cursor.fetchall()
    conn.close()
    return results

def get_player_counts(csv_path):
    if not os.path.exists(csv_path):
        return {}
    df = pd.read_csv(csv_path)
    counts = {}
    for col in ['row 1 expected player', 'row 2 expected player 2']:
        if col in df.columns:
            for name in df[col].dropna():
                name = name.strip()
                counts[name] = counts.get(name, 0) + 1
    return counts

def download_video(youtube_id, output_dir, max_retries=3):
    import time
    processor = ProdWttVideoProcessor(backend="pytorch-cpu", device="cpu")
    video_url = f"https://www.youtube.com/watch?v={youtube_id}"
    
    for attempt in range(max_retries):
        try:
            video_path = processor.download_video(video_url, output_dir)
            if video_path and os.path.exists(video_path):
                return video_path
        except Exception as e:
            print(f"    Download error: {e}")
            
        if attempt < max_retries - 1:
            wait_time = 15 * (attempt + 1)
            print(f"    Download attempt {attempt+1}/{max_retries} failed. Retrying in {wait_time} seconds...")
            time.sleep(wait_time)
            
    return None

def extract_and_dedup(video_path, start_sec, out_dir, player_name, processor, max_frames=15):
    import glob
    import shutil
    from ocr_utils import normalize_text, is_similar
    
    raw_dir = os.path.join(out_dir, "raw")
    unique_dir = os.path.join(out_dir, "unique")
    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(unique_dir, exist_ok=True)
    
    # Extract 1 frame every 15 seconds for 20 minutes (80 frames to search through)
    cmd = [
        'ffmpeg', '-y', '-v', 'error',
        '-ss', str(start_sec + 60),
        '-t', '1200',
        '-i', video_path,
        '-vf', 'fps=1/15',
        '-q:v', '2',
        os.path.join(raw_dir, 'raw_frame_%05d.jpg')
    ]
    subprocess.run(cmd, check=True)
    
    unique_count = 0
    seen_states = set()
    
    player_norm = normalize_text(player_name)
    
    raw_frames = sorted(glob.glob(os.path.join(raw_dir, "*.jpg")))
    for frame_path in raw_frames:
        if unique_count >= max_frames:
            break
            
        score, cropped_path = processor.get_scoreboard(frame_path)
        if not score.success:
            continue
            
        p1_norm = normalize_text(score.player1)
        p2_norm = normalize_text(score.player2)
        
        # Verify the target player is actually on this scoreboard
        if player_norm not in p1_norm and player_norm not in p2_norm and not is_similar(player_norm, p1_norm) and not is_similar(player_norm, p2_norm):
            continue
            
        # Deduplicate using mathematical game state instead of raw pixels
        state_key = (score.set1, score.set2, score.game1, score.game2)
        if state_key not in seen_states:
            seen_states.add(state_key)
            out_path = os.path.join(unique_dir, f"frame_{unique_count:05d}.jpg")
            if os.path.exists(cropped_path):
                shutil.copy(cropped_path, out_path)
                unique_count += 1
                
    return unique_dir, unique_count

def main():
    parser = argparse.ArgumentParser(description="Mine training data for underrepresented players.")
    parser.add_argument("--days", type=int, default=7, help="Number of days to look back in the database")
    parser.add_argument("--target_frames", type=int, default=10, help="Target number of frames per player")
    parser.add_argument("--list_players", action="store_true", help="List players that will be added and exit without extracting")
    parser.add_argument("--extract_frames", action="store_true", help="Extract frames to ./mined_frames directory but DO NOT run Gemini/OCR")
    args = parser.parse_args()
    
    csv_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "test_data_sample.csv")
    
    print(f"Fetching matches from the last {args.days} days...")
    recent_matches = get_recent_matches(args.days)
    player_counts = get_player_counts(csv_path)
    
    underrepresented = {}
    # group by player to find best match to extract from
    for offset, youtube_id, player_name in recent_matches:
        if not player_name or " / " in player_name: # skip doubles teams
            continue
        count = player_counts.get(player_name, 0)
        if count < args.target_frames:
            if player_name not in underrepresented:
                underrepresented[player_name] = []
            underrepresented[player_name].append((youtube_id, offset))
            
    print(f"Found {len(underrepresented)} underrepresented singles players.")
    
    if not underrepresented:
        print("All recent players have enough data!")
        return
        
    if args.list_players:
        print("\n=== Players to be Mined ===")
        for player, matches in sorted(underrepresented.items()):
            current_count = player_counts.get(player, 0)
            frames_needed = args.target_frames - current_count
            print(f"- {player}: has {current_count} frames, needs {frames_needed} more (found in {len(matches)} recent matches)")
        print("===========================")
        return

    # Group tasks by youtube_id to minimize downloads
    videos_to_download = {}
    for player, matches in underrepresented.items():
        youtube_id, offset = matches[0] # just pick the first match
        if youtube_id not in videos_to_download:
            videos_to_download[youtube_id] = []
        videos_to_download[youtube_id].append((player, offset))
        
    script_dir = os.path.dirname(os.path.abspath(__file__))
    generate_script = os.path.join(script_dir, "generate_golden_testdata.py")
        
    import shutil
    
    if args.extract_frames:
        work_dir = os.path.join(os.getcwd(), "mined_frames")
        os.makedirs(work_dir, exist_ok=True)
        print(f"\n--- EXTRACT FRAMES ONLY MODE ---")
        print(f"Frames will be saved permanently to: {work_dir}")
        print("Gemini OCR will NOT be called.\n")
    else:
        work_dir = tempfile.mkdtemp()
        
    try:
        import torch
        processor = ProdWttVideoProcessor(backend="pytorch-cpu", device="cuda:0" if torch.cuda.is_available() else "cpu")
        processor.initialize_scoreboard_model()

        for youtube_id, tasks in videos_to_download.items():
            print(f"\nProcessing video {youtube_id} for {len(tasks)} players...")
            video_path = download_video(youtube_id, work_dir)
            if not video_path:
                print(f"Failed to download {youtube_id}")
                continue
                
            for player, offset in tasks:
                print(f"  Extracting frames for {player} at offset {offset}s...")
                player_dir = os.path.join(work_dir, player.replace(" ", "_"))
                unique_dir, count = extract_and_dedup(video_path, offset, player_dir, player, processor, max_frames=args.target_frames)
                
                if count > 0:
                    if args.extract_frames:
                        print(f"  [SUCCESS] Extracted {count} unique frames for {player} in {unique_dir}")
                    else:
                        print(f"  Running Gemini OCR and appending {count} frames for {player}...")
                        json_out = os.path.join(player_dir, "results.json")
                        
                        cmd = [
                            sys.executable, generate_script,
                            "--image_dir", unique_dir,
                            "--output_file", json_out,
                            "--append_csv", csv_path
                        ]
                        subprocess.run(cmd, check=True)
                else:
                    print(f"  No valid frames found for {player}.")
    finally:
        if not args.extract_frames and os.path.exists(work_dir):
            shutil.rmtree(work_dir)

    print("\nData mining complete!")

if __name__ == "__main__":
    main()
