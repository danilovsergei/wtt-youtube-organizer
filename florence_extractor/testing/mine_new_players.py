import os
import sys
import argparse
import psycopg2
import pandas as pd
import subprocess
import cv2
import numpy as np
import time
import json
import glob
import shutil
import uuid

DATABASE_URL = "<DATABASE_URL_REDACTED>"
BOTTOM_PERCENT = 0.14
LEFT_PERCENT = 0.40
DIFF_THRESHOLD = 3.0
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
            print(
                f"    Download attempt {attempt+1}/{max_retries} failed. Retrying in {wait_time} seconds...")
            time.sleep(wait_time)

    return None


def extract_and_dedup(video_path, start_sec, out_dir, player_name, processor, max_frames=15):
    from ocr_utils import normalize_text, is_similar

    raw_dir = os.path.join(out_dir, "raw")
    unique_dir = os.path.join(out_dir, "unique")
    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(unique_dir, exist_ok=True)

    cmd = [
        'ffmpeg', '-y', '-v', 'error',
        '-ss', str(start_sec + 60),
        '-t', '3600',
        '-i', video_path,
        '-vf', 'fps=1/30',
        '-q:v', '2',
        os.path.join(raw_dir, 'raw_frame_%05d.jpg')
    ]
    subprocess.run(cmd, check=True)

    unique_count = 0
    seen_states = set()

    player_norm = normalize_text(player_name)

    raw_frames = sorted(glob.glob(os.path.join(raw_dir, "*.jpg")))
    import random
    random.seed(42)
    random.shuffle(raw_frames)

    for frame_path in raw_frames:
        if unique_count >= max_frames:
            break

        score, cropped_path = processor.get_scoreboard(frame_path)
        if not score.success:
            continue

        p1_norm = normalize_text(score.player1)
        p2_norm = normalize_text(score.player2)

        if player_norm not in p1_norm and player_norm not in p2_norm and not is_similar(player_norm, p1_norm) and not is_similar(player_norm, p2_norm):
            continue

        state_key = (score.set1, score.set2, score.game1, score.game2)
        if state_key not in seen_states:
            seen_states.add(state_key)
            out_path = os.path.join(
                unique_dir, f"frame_{unique_count:05d}.jpg")
            if os.path.exists(cropped_path):
                shutil.copy(cropped_path, out_path)
                unique_count += 1

    # Clean up raw frames
    shutil.rmtree(raw_dir, ignore_errors=True)

    return unique_dir, unique_count


def poll_batches(csv_path):
    from google import genai
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("GEMINI_API_KEY environment variable is not set.")
        sys.exit(1)

    client = genai.Client(api_key=api_key)
    state_file = os.path.join(os.path.dirname(
        os.path.abspath(__file__)), "active_batches.json")

    if not os.path.exists(state_file):
        print("No active batches found.")
        return

    with open(state_file, "r") as f:
        state = json.load(f)

    if not state:
        print("No active batches found.")
        return

    jobs_to_remove = []

    testdata_dir = os.path.join(os.path.dirname(csv_path), "testdata")
    os.makedirs(testdata_dir, exist_ok=True)

    for job_name, local_mapping in state.items():
        print(f"Checking job: {job_name}...")
        try:
            job = client.batches.get(name=job_name)
            print(
                f"  State: {job.state.name if hasattr(job.state, 'name') else job.state}")

            if hasattr(job, "done") and getattr(job, "done") is True:
                if job.state.name == "JOB_STATE_SUCCEEDED":
                    print(
                        f"  Job {job_name} succeeded! Downloading results...")

                    if not job.dest or not hasattr(job.dest, 'file_name') or not job.dest.file_name:
                        print(
                            "  Error: Cannot find output file URI in job destination.")
                        jobs_to_remove.append(job_name)
                        continue

                    # Download the JSONL output file
                    output_bytes = client.files.download(
                        file=job.dest.file_name)
                    output_text = output_bytes.decode('utf-8')

                    # Parse JSONL and append to CSV
                    new_rows = []
                    for line in output_text.strip().split('\\n'):
                        if not line:
                            continue
                        res_obj = json.loads(line)
                        req_name = res_obj.get("request", {}).get("name")

                        if req_name not in local_mapping:
                            continue

                        # Extract the response text
                        try:
                            # Safely navigate GenerateContentResponse structure
                            cand = res_obj.get("response", {}).get(
                                "candidates", [])[0]
                            text = cand.get("content", {}).get(
                                "parts", [])[0].get("text", "")

                            # Clean markdown formatting if present
                            if text.startswith("```json"):
                                text = text[7:]
                            if text.endswith("```"):
                                text = text[:-3]
                            text = text.strip()

                            data = json.loads(text)
                        except Exception as e:
                            print(
                                f"  Failed to parse result for {req_name}: {e}")
                            data = None

                        if not data:
                            continue

                        local_info = local_mapping[req_name]
                        img_source_path = local_info["local_path"]

                        p1 = data.get("player1", "")
                        p2 = data.get("player2", "")
                        s1 = data.get("p1_sets", 0)
                        g1 = data.get("p1_points", 0)
                        s2 = data.get("p2_sets", 0)
                        g2 = data.get("p2_points", 0)

                        # Only add if it's not the empty format
                        if not p1 and not p2:
                            continue

                        if os.path.exists(img_source_path):
                            new_filename = f"cropped_{uuid.uuid4().hex[:8]}.jpg"
                            new_filepath = os.path.join(
                                testdata_dir, new_filename)
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
                        df = pd.read_csv(csv_path) if os.path.exists(
                            csv_path) else pd.DataFrame()
                        new_df = pd.DataFrame(new_rows)
                        df = pd.concat([df, new_df], ignore_index=True)
                        df.to_csv(csv_path, index=False)
                        print(
                            f"  Successfully appended {len(new_rows)} new rows to CSV!")

                    jobs_to_remove.append(job_name)

                    # Optional: We could delete the uploaded files from Gemini File API here,
                    # but they automatically expire after 48 hours anyway.

                elif job.state.name in ["JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_EXPIRED"]:
                    print(f"  Job failed with state: {job.state.name}")
                    jobs_to_remove.append(job_name)
        except Exception as e:
            print(f"Error checking {job_name}: {e}")

    # Clean up finished jobs
    for j in jobs_to_remove:
        # Also clean up local image directory for this job
        try:
            first_req = list(state[j].keys())[0]
            player_unique_dir = os.path.dirname(
                state[j][first_req]["local_path"])
            player_root_dir = os.path.dirname(player_unique_dir)
            if os.path.exists(player_root_dir):
                shutil.rmtree(player_root_dir, ignore_errors=True)
        except:
            pass
        del state[j]

    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)


def submit_local_frames_to_batch():
    from google import genai
    from google.genai import types
    import time
    import glob

    work_dir = os.path.join(os.getcwd(), "mined_frames")
    if not os.path.exists(work_dir):
        print(f"Error: {work_dir} does not exist.")
        return

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("GEMINI_API_KEY environment variable is not set.")
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

    inlined_requests = []
    local_mapping = {}
    req_index = int(time.time())

    player_dirs = [d for d in os.listdir(
        work_dir) if os.path.isdir(os.path.join(work_dir, d))]
    if not player_dirs:
        print(f"No player directories found in {work_dir}")
        return

    for player_dir_name in player_dirs:
        player_name = player_dir_name.replace("_", " ")
        unique_dir = os.path.join(work_dir, player_dir_name, "unique")
        if not os.path.exists(unique_dir):
            continue

        frames = sorted(glob.glob(os.path.join(unique_dir, "*.jpg")))
        if not frames:
            continue

        import concurrent.futures

        def _upload_frame(f_path, r_name, p_name):
            up_file = client.files.upload(file=f_path)
            req = types.InlinedRequest(
                metadata={"req_id": r_name},
                contents=[
                    types.Content(role="user", parts=[
                        types.Part.from_uri(
                            file_uri=up_file.uri, mime_type=up_file.mime_type),
                        types.Part.from_text(text=prompt)
                    ])
                ]
            )
            return r_name, {"local_path": f_path, "player": p_name}, req

        print(
            f"Uploading {len(frames)} frames for {player_name} concurrently...")
        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
            futures = []
            for f in frames:
                req_name = f"req_{req_index}"
                req_index += 1
                futures.append(executor.submit(
                    _upload_frame, f, req_name, player_name))

            for future in concurrent.futures.as_completed(futures):
                try:
                    r_name, mapping_entry, req = future.result()
                    local_mapping[r_name] = mapping_entry
                    inlined_requests.append(req)
                except Exception as e:
                    print(f"  Error uploading frame: {e}")

    if not inlined_requests:
        print("\nNo valid frames to submit to Gemini.")
        return

    print(
        f"\nSubmitting Gemini Batch Job for {len(inlined_requests)} total frames...")
    job = client.batches.create(
        model="gemini-3.6-flash-lite",
        src=inlined_requests
    )

    print(f"\nBatch Job Created Successfully!")
    print(f"Job ID: {job.name}")
    print("Run this script with --poll_for_images later to fetch the results and update the CSV.")

    state_file = os.path.join(os.path.dirname(
        os.path.abspath(__file__)), "active_batches.json")
    state = {}
    import json
    if os.path.exists(state_file):
        with open(state_file, "r") as f:
            state = json.load(f)

    state[job.name] = local_mapping
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)


def main():

    parser = argparse.ArgumentParser(
        description="Mine training data for underrepresented players.")
    parser.add_argument("--days", type=int, default=7,
                        help="Number of days to look back in the database")
    parser.add_argument("--target_frames", type=int, default=10,
                        help="Target number of frames per player")
    parser.add_argument("--list_players", action="store_true",
                        help="List players that will be added and exit without extracting")
    parser.add_argument("--extract_frames", action="store_true",
                        help="Extract frames to ./mined_frames directory but DO NOT run Gemini/OCR")
    parser.add_argument("--poll_for_images", action="store_true",
                        help="Poll for completed Gemini Batch jobs and append their results to the CSV")
    parser.add_argument("--submit_local_frames", action="store_true",
                        help="Upload already extracted frames from ./mined_frames to Gemini Batch API")
    args = parser.parse_args()

    csv_path = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "test_data_sample.csv")

    if args.poll_for_images:
        print("Polling active Gemini Batch Jobs...")
        poll_batches(csv_path)
        return

    if args.submit_local_frames:
        print("Submitting local frames from ./mined_frames to Gemini Batch API...")
        submit_local_frames_to_batch()
        return

    print(f"Fetching matches from the last {args.days} days...")
    recent_matches = get_recent_matches(args.days)
    player_counts = get_player_counts(csv_path)

    underrepresented = {}
    for offset, youtube_id, player_name in recent_matches:
        if not player_name or " / " in player_name:
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
        print("\\n=== Players to be Mined ===")
        for player, matches in sorted(underrepresented.items()):
            current_count = player_counts.get(player, 0)
            frames_needed = args.target_frames - current_count
            print(
                f"- {player}: has {current_count} frames, needs {frames_needed} more (found in {len(matches)} recent matches)")
        print("===========================")
        return

    videos_to_download = {}
    for player, matches in underrepresented.items():
        youtube_id, offset = matches[0]
        if youtube_id not in videos_to_download:
            videos_to_download[youtube_id] = []
        videos_to_download[youtube_id].append((player, offset))

    script_dir = os.path.dirname(os.path.abspath(__file__))

    work_dir = os.path.join(os.getcwd(), "mined_frames")
    os.makedirs(work_dir, exist_ok=True)

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

    import torch
    processor = ProdWttVideoProcessor(
        backend="pytorch-cpu", device="cuda:0" if torch.cuda.is_available() else "cpu")
    processor.initialize_scoreboard_model()

    if not args.extract_frames:
        from google import genai
        from google.genai import types
        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            print("GEMINI_API_KEY environment variable is not set.")
            sys.exit(1)
        client = genai.Client(api_key=api_key)

    inlined_requests = []
    local_mapping = {}
    req_index = int(time.time())

    for youtube_id, tasks in videos_to_download.items():
        print(f"\\nProcessing video {youtube_id} for {len(tasks)} players...")
        video_path = download_video(youtube_id, work_dir)
        if not video_path:
            print(f"Failed to download {youtube_id}")
            continue

        for player, offset in tasks:
            print(f"  Extracting frames for {player} at offset {offset}s...")
            player_dir = os.path.join(work_dir, player.replace(" ", "_"))
            unique_dir, count = extract_and_dedup(
                video_path, offset, player_dir, player, processor, max_frames=args.target_frames)

            if count > 0:
                print(
                    f"  [SUCCESS] Extracted {count} unique frames for {player} in {unique_dir}")

                if not args.extract_frames:
                    frames = sorted(
                        glob.glob(os.path.join(unique_dir, '*.jpg')))
        import concurrent.futures

        def _upload_frame(f_path, r_name, p_name):
            up_file = client.files.upload(file=f_path)
            req = types.InlinedRequest(
                metadata={"req_id": r_name},
                contents=[
                    types.Content(role="user", parts=[
                        types.Part.from_uri(
                            file_uri=up_file.uri, mime_type=up_file.mime_type),
                        types.Part.from_text(text=prompt)
                    ])
                ]
            )
            return r_name, {"local_path": f_path, "player": p_name}, req

        print(f"Uploading {len(frames)} frames for {player} concurrently...")
        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
            futures = []
            for f in frames:
                req_name = f"req_{req_index}"
                req_index += 1
                futures.append(executor.submit(
                    _upload_frame, f, req_name, player_name))

            for future in concurrent.futures.as_completed(futures):
                try:
                    r_name, mapping_entry, req = future.result()
                    local_mapping[r_name] = mapping_entry
                    inlined_requests.append(req)
                except Exception as e:
                    print(f"  Error uploading frame: {e}")
            else:
                print(f"  No valid frames found for {player}.")

        # Clean up huge video file immediately after processing its tasks
        try:
            os.remove(video_path)
        except:
            pass

    if args.extract_frames:
        print("\\n--- EXTRACT FRAMES ONLY MODE ---")
        print(f"Frames saved permanently to: {work_dir}")
        print("Gemini Batch API was NOT called.\\n")
        return

    if not inlined_requests:
        print("\\nNo valid frames to submit to Gemini.")
        return

    print(
        f"\\nSubmitting Gemini Batch Job for {len(inlined_requests)} total frames...")

    job = client.batches.create(
        model="gemini-3.6-flash-lite",
        src=inlined_requests
    )

    print(f"\\nBatch Job Created Successfully!")
    print(f"Job ID: {job.name}")
    print("Run this script with --poll_for_images later to fetch the results and update the CSV.")

    state_file = os.path.join(os.path.dirname(
        os.path.abspath(__file__)), "active_batches.json")
    state = {}
    if os.path.exists(state_file):
        with open(state_file, "r") as f:
            state = json.load(f)

    state[job.name] = local_mapping
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)


if __name__ == "__main__":
    main()
