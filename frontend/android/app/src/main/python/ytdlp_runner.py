import json
import yt_dlp

def get_ytdlp_version():
    try:
        return str(yt_dlp.version.__version__)
    except Exception as e:
        return f"UNKNOWN: {e}"

def extract_stream_metadata(youtube_id):
    url = f"https://www.youtube.com/watch?v={youtube_id}"
    ydl_opts = {
        "skip_download": True,
        "quiet": True,
        "no_warnings": True,
        "extract_flat": False,
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        manifest = ydl.extract_info(url, download=False)
        formats = manifest.get("formats", [])
        http_headers = manifest.get("http_headers", {})
        result = {
            "id": manifest.get("id", youtube_id),
            "title": manifest.get("title", ""),
            "formats": formats,
            "http_headers": http_headers,
        }
        return json.dumps(result)

def update_ytdlp():
    try:
        import pip
        if hasattr(pip, "main"):
            exit_code = pip.main(["install", "--upgrade", "yt-dlp"])
        else:
            from pip._internal.cli.main import main as pip_main
            exit_code = pip_main(["install", "--upgrade", "yt-dlp"])
        return f"SUCCESS (exit_code={exit_code})"
    except Exception as e:
        return f"ERROR: {str(e)}"
