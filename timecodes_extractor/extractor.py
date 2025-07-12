#!/usr/bin/env python3

import os
import sys
import re
import argparse
import yt_dlp  # Import the yt-dlp library
from yt_dlp.utils import download_range_func  # Import for download_ranges
import traceback  # Import for more detailed error logging


def get_video_duration(video_url: str) -> float | None:
    """
    Retrieves the duration of a video using the yt-dlp Python module.

    Args:
        video_url: The URL or local path of the video.

    Returns:
        The duration of the video in seconds, or None if an error occurs.
    """
    ydl_opts = {
        'quiet': True,
        'no_warnings': True,
        'skip_download': True,  # Only fetch metadata, don't download the video
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
                if info_dict.get('is_live') or info_dict.get('live_status') == 'is_live':
                    print(
                        f"Warning: '{video_url}' appears to be a live stream. Live streams may not have a fixed duration or may report 0.")
                    return 0

                print(
                    f"Error: Could not find 'duration' in yt-dlp info for {video_url}.")
                return None

    except yt_dlp.utils.DownloadError as e:
        print(
            f"yt-dlp library error while fetching video info for '{video_url}':")
        print(f"  Details: {e}")
        return None
    except Exception as e:
        print(
            f"An unexpected error occurred with yt-dlp library while getting video duration for '{video_url}': {e}")
        print("--- Full Traceback for get_video_duration ---")
        traceback.print_exc()
        print("--- End Traceback ---")
        return None


def sanitize_filename(name: str) -> str:
    """Sanitizes a string to be used as a valid filename component."""
    name = re.sub(r'[^\w\s-]', '', name)
    name = re.sub(r'[-\s]+', '-', name).strip('-_')
    return name[:100]


def extract_clips(video_url: str, video_duration: float, output_base_dir: str = "extracted_video_clips"):
    """
    Extracts 1-second clips from the video at 5-minute intervals using a single yt-dlp call.

    Args:
        video_url: The URL or local path of the video.
        video_duration: The total duration of the video in seconds.
        output_base_dir: The base directory to save extracted clips.
    """
    if video_duration <= 0:
        print("Video duration is zero or invalid. Cannot extract clips.")
        return

    video_id_raw = video_url.split(
        '/')[-1].split('?')[0].replace('watch?v=', '') or "video"
    sanitized_video_id = sanitize_filename(video_id_raw)
    output_dir = os.path.join(output_base_dir, sanitized_video_id)

    try:
        os.makedirs(output_dir, exist_ok=True)
        print(f"Output directory: {os.path.abspath(output_dir)}")
    except OSError as e:
        print(f"Error creating output directory {output_dir}: {e}")
        returnW
    # TODO fix the issue that every 5 minutes does not work , but every hour works.
    # yt-dlp seems to have a problem with too many segments
    # check it with cli yt-dlp
    interval_seconds = 50 * 60
    clip_duration_seconds = 1

    time_ranges = []
    current_marker_time = 0.0
    segment_index = 0  # For naming consistency if needed, though section_start/end is better

    while current_marker_time < video_duration:
        start_time = current_marker_time
        end_time = start_time + clip_duration_seconds
        if end_time > video_duration:
            # Optional: if you want to include a partial last segment, adjust end_time
            # end_time = video_duration
            # However, for 1-second clips, it's usually better to skip if it exceeds.
            print(
                f"Calculated segment from {start_time:.2f}s to {end_time:.2f}s would exceed video duration ({video_duration:.2f}s). Final full segment not included.")
            break
        time_ranges.append([start_time, end_time])
        current_marker_time += interval_seconds
        segment_index += 1

    if not time_ranges:
        print(
            "No time ranges to extract (e.g., video duration too short for any intervals).")
        return

    print(f"Calculated {len(time_ranges)} time ranges for extraction.")

    # Use section_start and section_end for unique filenames per downloaded range
    # The 'd' in %(section_start_time)d means integer.
    # yt-dlp uses section_start and section_end for download_ranges output template.

    output_template_path = os.path.join(
        output_dir, "clip_%(section_start)s-%(section_end)s.%(ext)s")

    ydl_opts_extract = {
        'listformats_table': True,
        # 'verbose': True,
        'outtmpl': {
            'default': 'clip-%(section_start)s-%(section_end)s.%(ext)s'
        },
        # 'ignoreerrors': 'only_download',
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
        # prevents ffmpeg downloader to fail while using picture fragments
        'nopart': True
    }

    print(
        f"\nAttempting to extract all {len(time_ranges)} segments in a single call using yt-dlp library...")
    print(f"  Output template: {output_template_path}")
    print(f"options: {ydl_opts_extract}")
    num_clips_extracted = 0  # We'll assume success if no error, or count files later
    try:
        with yt_dlp.YoutubeDL(ydl_opts_extract) as ydl:
            # The download method will process all ranges.
            # The return code from ydl.download is 0 on success, 1 on error typically.
            result_code = ydl.download([video_url])
            if result_code == 0:
                print(
                    f"Successfully processed download request for {len(time_ranges)} segments.")
                # To be more precise, we can count the actual files created
                # This is a simple way; more robust would be to check against expected filenames
                # based on time_ranges and the output_template.
                # For now, we assume yt-dlp handles the creation or errors out.
                # Assume all were attempted and created if no error
                num_clips_extracted = len(time_ranges)
            else:
                print(
                    f"yt-dlp download process finished with a non-zero exit code: {result_code}")

    except yt_dlp.utils.DownloadError as e:
        print(f"yt-dlp library error during batch segment extraction:")
        print(f"  Error details: {e}")
        print("  This could be due to issues with ffmpeg, network problems, or the video source.")
        print("  Ensure ffmpeg is installed and in your system's PATH.")
        print("--- Full Traceback for DownloadError ---")
        traceback.print_exc()
        print("--- End Traceback ---")
    except Exception as e:
        print(
            f"An unexpected error occurred with yt-dlp library during batch clip extraction: {e}")
        print("--- Full Traceback for unexpected error in extract_clips ---")
        traceback.print_exc()
        print("--- End Traceback ---")

    # After the download attempt, verify how many files were actually created
    # This is a more accurate count.
    actual_files_created = 0
    if os.path.exists(output_dir):
        for start, end in time_ranges:
            # Construct expected filename pattern (without extension initially)
            # Note: %(section_start)s is float, so cast to int for filename matching if needed
            # or use a glob pattern. Here we assume yt-dlp uses the float values.
            expected_base = f"clip_{start}-{end}"
            # Glob for files starting with this base, as extension can vary
            matching_files = [f for f in os.listdir(
                output_dir) if f.startswith(expected_base)]
            if matching_files:
                actual_files_created += 1

    if actual_files_created > 0:
        print(
            f"\nFinished. Verified {actual_files_created} clip(s) in {os.path.abspath(output_dir)}.")
    elif len(time_ranges) > 0:
        print(f"\nDownload process completed, but no clips were verified in the output directory. Check logs for errors.")
    else:  # This case should be caught by "No time ranges to extract" earlier
        print("\nNo clips extracted.")


def main():
    parser = argparse.ArgumentParser(
        description="Extract 1-second video clips at 5-minute intervals using the yt-dlp Python module. Requires ffmpeg to be installed."
    )
    parser.add_argument(
        "--video_url",
        help="The URL or local file path of the video.",
        required=True
    )
    parser.add_argument(
        "--output_dir_base",
        default="extracted_video_clips",
        help="Base directory to save extracted clips (default: extracted_video_clips)"
    )

    args = parser.parse_args()
    video_url = args.video_url
    output_base_dir_arg = args.output_dir_base

    print(f"--- yt-dlp Clip Extractor (Python Module Mode) ---")
    print(f"Attempting to process video: {video_url}")
    print(f"Base output directory: {output_base_dir_arg}")
    print("Reminder: This script requires 'ffmpeg' to be installed and in your system's PATH for clip extraction.")

    duration = get_video_duration(video_url)

    if duration is None:
        print("Could not determine video duration due to an error. Exiting.")
        sys.exit(1)

    print(
        f"Reported video duration: {duration:.2f} seconds (approx. {duration/60:.2f} minutes).")

    extract_clips(video_url, duration, output_base_dir_arg)


if __name__ == "__main__":
    main()
