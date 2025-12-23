#!/usr/bin/env python3

import os
import sys
import re
import argparse
import time
import subprocess
import yt_dlp
from yt_dlp.utils import download_range_func
import traceback


class PerformanceLogger:
    """Logs performance metrics for comparison."""

    def __init__(self):
        self.metrics = {}
        self.start_times = {}

    def start(self, operation: str):
        """Start timing an operation."""
        self.start_times[operation] = time.time()

    def end(self, operation: str):
        """End timing an operation and store duration."""
        if operation in self.start_times:
            duration = time.time() - self.start_times[operation]
            self.metrics[operation] = duration
            return duration
        return 0

    def log_summary(self, method: str, num_frames: int):
        """Print performance summary."""
        print("\n" + "=" * 60)
        print(f"PERFORMANCE SUMMARY - Method: {method}")
        print("=" * 60)
        total_time = 0
        for op, duration in self.metrics.items():
            print(f"  {op}: {duration:.2f}s")
            total_time += duration
        print("-" * 60)
        print(f"  Total time: {total_time:.2f}s")
        print(f"  Frames extracted: {num_frames}")
        if num_frames > 0:
            print(f"  Average per frame: {total_time / num_frames:.2f}s")
        print("=" * 60)


def get_video_duration(video_url: str) -> float | None:
    """
    Retrieves the duration of a video using the yt-dlp Python module.
    """
    ydl_opts = {
        'quiet': True,
        'no_warnings': True,
        'skip_download': True,
        'verbose': False,
    }
    print(f"Fetching video info for: {video_url} using yt-dlp module...")
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info_dict = ydl.extract_info(video_url, download=False)
            duration = info_dict.get('duration')

            if duration is not None:
                return float(duration)
            else:
                if (info_dict.get('is_live') or
                        info_dict.get('live_status') == 'is_live'):
                    print(f"Warning: '{video_url}' appears to be a live "
                          "stream.")
                    return 0

                print(f"Error: Could not find 'duration' in yt-dlp info "
                      f"for {video_url}.")
                return None

    except yt_dlp.utils.DownloadError as e:
        print(f"yt-dlp library error while fetching video info for "
              f"'{video_url}':")
        print(f"  Details: {e}")
        return None
    except Exception as e:
        print(f"An unexpected error occurred with yt-dlp library: {e}")
        traceback.print_exc()
        return None


def sanitize_filename(name: str) -> str:
    """Sanitizes a string to be used as a valid filename component."""
    name = re.sub(r'[^\w\s-]', '', name)
    name = re.sub(r'[-\s]+', '-', name).strip('-_')
    return name[:100]


def download_full_video(video_url: str, output_dir: str,
                        perf: PerformanceLogger) -> str | None:
    """
    Downloads the full video at 480p using yt-dlp.

    Returns:
        Path to downloaded video file, or None if failed.
    """
    video_path = os.path.join(output_dir, "full_video.mp4")

    # Skip if already downloaded
    if os.path.exists(video_path):
        print(f"Video already downloaded: {video_path}")
        return video_path

    ydl_opts = {
        'format': 'bv*[height<=480]',  # Video only, no audio
        'outtmpl': video_path,
        'quiet': False,
        'no_warnings': False,
    }

    print(f"Downloading full video at 480p...")
    perf.start("download_video")

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([video_url])

        perf.end("download_video")

        if os.path.exists(video_path):
            file_size = os.path.getsize(video_path) / (1024 * 1024)
            print(f"Video downloaded: {video_path} ({file_size:.1f} MB)")
            return video_path
        else:
            print("Error: Video file not found after download.")
            return None

    except Exception as e:
        perf.end("download_video")
        print(f"Error downloading video: {e}")
        traceback.print_exc()
        return None


def extract_frames_from_local_video(video_path: str, video_duration: float,
                                    output_dir: str,
                                    perf: PerformanceLogger) -> int:
    """
    Extract frames from a local video file using ffmpeg.

    Args:
        video_path: Path to the local video file.
        video_duration: Total duration of the video in seconds.
        output_dir: Directory to save extracted frames.

    Returns:
        Number of frames extracted.
    """
    interval_seconds = 3 * 60  # 3 minutes
    frames_extracted = 0

    # Calculate timestamps
    timestamps = []
    current_time = 0.0
    while current_time < video_duration:
        timestamps.append(current_time)
        current_time += interval_seconds

    if not timestamps:
        print("No timestamps to extract.")
        return 0

    print(f"Extracting {len(timestamps)} frames from local video...")
    perf.start("extract_frames")

    for ts in timestamps:
        # Format timestamp for ffmpeg (HH:MM:SS.mmm)
        hours = int(ts // 3600)
        minutes = int((ts % 3600) // 60)
        seconds = ts % 60
        ts_str = f"{hours:02d}:{minutes:02d}:{seconds:06.3f}"

        output_file = os.path.join(output_dir, f"clip-{ts}-0.001.jpg")

        cmd = [
            'ffmpeg', '-y',
            '-ss', ts_str,
            '-i', video_path,
            '-frames:v', '1',
            '-q:v', '2',
            output_file
        ]

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, check=True)
            if os.path.exists(output_file):
                frames_extracted += 1
        except subprocess.CalledProcessError as e:
            print(f"ffmpeg error at {ts_str}: {e.stderr}")

    perf.end("extract_frames")
    print(f"Extracted {frames_extracted} frames.")
    return frames_extracted


def extract_clips_direct(video_url: str, video_duration: float,
                         output_dir: str, perf: PerformanceLogger) -> int:
    """
    Extracts clips directly from YouTube using yt-dlp (original method).

    Returns:
        Number of clips extracted.
    """
    if video_duration <= 0:
        print("Video duration is zero or invalid. Cannot extract clips.")
        return 0

    interval_seconds = 3 * 60
    clip_duration_seconds = 1

    time_ranges = []
    current_marker_time = 0.0

    while current_marker_time < video_duration:
        start_time = current_marker_time
        end_time = start_time + clip_duration_seconds
        if end_time > video_duration:
            break
        time_ranges.append([start_time, 0.001])
        current_marker_time += interval_seconds

    if not time_ranges:
        print("No time ranges to extract.")
        return 0

    print(f"Calculated {len(time_ranges)} time ranges for extraction.")

    ydl_opts_extract = {
        'listformats_table': True,
        'outtmpl': {
            'default': os.path.join(
                output_dir, 'clip-%(section_start)s-%(section_end)s.%(ext)s')
        },
        'format': 'bv*[height<=480]',
        'download_ranges_as_images': True,
        'skip_unavailable_fragments': True,
        'concurrent_fragment_downloads': 1,
        'updatetime': True,
        'allow_playlist_files': True,
        'clean_infojson': True,
        'prefer_ffmpeg': True,
        'youtube_include_dash_manifest': True,
        'youtube_include_hls_manifest': True,
        'extract_flat': 'discard_in_playlist',
        'download_ranges': yt_dlp.utils.download_range_func([], time_ranges),
        'geo_bypass': True,
        'nopart': True
    }

    print(f"Extracting {len(time_ranges)} clips directly from YouTube...")
    perf.start("extract_direct")

    num_clips_extracted = 0
    try:
        with yt_dlp.YoutubeDL(ydl_opts_extract) as ydl:
            result_code = ydl.download([video_url])
            if result_code == 0:
                num_clips_extracted = len(time_ranges)

    except yt_dlp.utils.DownloadError as e:
        print(f"yt-dlp error during extraction: {e}")
        traceback.print_exc()
    except Exception as e:
        print(f"Unexpected error during extraction: {e}")
        traceback.print_exc()

    perf.end("extract_direct")
    return num_clips_extracted


def main():
    parser = argparse.ArgumentParser(
        description="Extract video frames at 3-minute intervals. "
                    "Requires ffmpeg to be installed."
    )
    parser.add_argument(
        "--video_url",
        help="The URL or local file path of the video.",
        required=True
    )
    parser.add_argument(
        "--output_dir_base",
        default="extracted_video_clips",
        help="Base directory to save extracted clips "
             "(default: extracted_video_clips)"
    )
    parser.add_argument(
        "--download_full_video",
        action="store_true",
        help="Download full video first, then extract frames locally. "
             "Faster for multiple frames but uses more disk space."
    )

    args = parser.parse_args()
    video_url = args.video_url
    output_base_dir = args.output_dir_base
    use_full_download = args.download_full_video

    # Performance logging
    perf = PerformanceLogger()

    print("=" * 60)
    print("yt-dlp Frame Extractor")
    print("=" * 60)
    print(f"Video URL: {video_url}")
    print(f"Output directory: {output_base_dir}")
    print(
        f"Method: {'Full video download' if use_full_download else 'Direct extraction'}")
    print("=" * 60)

    # Get video duration
    perf.start("get_duration")
    duration = get_video_duration(video_url)
    perf.end("get_duration")

    if duration is None:
        print("Could not determine video duration. Exiting.")
        sys.exit(1)

    print(f"Video duration: {duration:.2f}s ({duration/60:.2f} minutes)")

    # Setup output directory
    video_id_raw = (video_url.split('/')[-1].split('?')[0]
                    .replace('watch?v=', '') or "video")
    sanitized_video_id = sanitize_filename(video_id_raw)
    output_dir = os.path.join(output_base_dir, sanitized_video_id)

    try:
        os.makedirs(output_dir, exist_ok=True)
        print(f"Output directory: {os.path.abspath(output_dir)}")
    except OSError as e:
        print(f"Error creating output directory: {e}")
        sys.exit(1)

    # Extract frames using selected method
    num_frames = 0
    method_name = ""

    if use_full_download:
        method_name = "Full Video Download + FFmpeg"
        video_path = download_full_video(video_url, output_dir, perf)
        if video_path:
            num_frames = extract_frames_from_local_video(
                video_path, duration, output_dir, perf)
    else:
        method_name = "Direct yt-dlp Extraction"
        num_frames = extract_clips_direct(video_url, duration, output_dir,
                                          perf)

    # Print performance summary
    perf.log_summary(method_name, num_frames)


if __name__ == "__main__":
    main()
