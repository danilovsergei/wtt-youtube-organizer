# Matchfinder CLI

A wrapper to run match-finder Docker container with automatic GPU group detection for Intel OpenVINO acceleration.

## Prerequisites

- Docker installed and running
- `DATABASE_URL` environment variable set (PostgreSQL connection string for Supabase)
- Intel GPU (for OpenVINO acceleration, optional but recommended)

## Commands

### Show New Streams (Dry Run)

Shows all not processed yet streams from Youtube WTT channel using yt-dlp. Last processed video fetched from the database

```bash
# Show new streams to stdout (no files created)
wtt-youtube-organizer matchfinder --show_new_streams

# To save new streams list to a json add -output_json
wtt-youtube-organizer matchfinder --show_new_streams --output_json /path/to/results.json
```

### Process New Streams

Find matches start timestamps in new streams and stores them to database.

```bash
# Process all new streams since last processed video stored in db
wtt-youtube-organizer matchfinder --process_new_streams

# To manually specify last processed video add your youtube VIDEO_ID
wtt-youtube-organizer matchfinder --process_new_streams VIDEO_ID
```

### Custom Docker Usage

For advanced use cases, pass arguments directly to the Docker container:

```bash
# Process a single YouTube video
wtt-youtube-organizer matchfinder --output_json /path/to/results.json -- --youtube_video "https://youtube.com/watch?v=xyz123"

# Extract only video metadata (no OCR processing)
wtt-youtube-organizer matchfinder --output_json /path/to/results.json -- --youtube_video "https://..." --only_extract_video_metadata
```

## Docker Image

The command uses the `wtt-stream-match-finder-openvino` Docker image. If not present, it will be built automatically from `florence_extractor/docker/`.

## GPU Acceleration

The CLI automatically detects Intel GPU groups (`video`, `render`) and configures Docker with:
- `/dev/dri` device access
- Appropriate group permissions

This enables OpenVINO GPU acceleration for the Florence2 OCR model.
