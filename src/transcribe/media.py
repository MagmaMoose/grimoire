"""ffmpeg/ffprobe helpers: probing, audio extraction, and lossless video cutting."""

import json
import os
import shutil
import subprocess
from datetime import datetime, timedelta

# Formats ffprobe reports for the container creation time.
_CREATION_FORMATS = (
    "%Y-%m-%dT%H:%M:%S.%f%z",
    "%Y-%m-%dT%H:%M:%S%z",
    "%Y-%m-%dT%H:%M:%S.%fZ",
    "%Y-%m-%dT%H:%M:%SZ",
)

# Every extension the pipeline treats as a recording, audio included. One list,
# matching the macOS app's own: two copies of it had drifted apart once already.
MEDIA_SUFFIXES = frozenset({".mov", ".mp4", ".m4v", ".m4a", ".qta", ".wav", ".mp3", ".mkv", ".avi"})

# OBS names its recordings "<YYYY-MM-DD HH-MM-SS>.<ext>". When container metadata
# carries no creation time, that filename is the next best clock reference.
_FILENAME_FORMATS = (
    "%Y-%m-%d %H-%M-%S",
    "%Y-%m-%d %H_%M_%S",
    "%Y%m%d_%H%M%S",
)


def _tool(name, fallback):
    """Resolve a CLI tool from PATH, falling back to the Homebrew location."""
    return shutil.which(name) or fallback


def ffmpeg_bin():
    return _tool("ffmpeg", "/opt/homebrew/bin/ffmpeg")


def ffprobe_bin():
    return _tool("ffprobe", "/opt/homebrew/bin/ffprobe")


def probe(path):
    """Return the ffprobe format dict for ``path`` ({} if probing fails)."""
    path = os.path.abspath(path)
    try:
        result = subprocess.run(
            [
                ffprobe_bin(),
                "-v",
                "error",
                "-show_format",
                "-print_format",
                "json",
                path,
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout).get("format", {})
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        return {}


def probe_duration(path):
    """Return the media duration in seconds, or 0.0 when it cannot be determined."""
    try:
        return float(probe(path).get("duration", 0.0))
    except (TypeError, ValueError):
        return 0.0


def recording_started_at(path):
    """Best-effort wall-clock start time of the recording.

    Tries the container's ``creation_time`` tag first, then an OBS-style
    timestamp in the filename, then the file's mtime minus its duration.
    Returns a naive local ``datetime``, or ``None`` if nothing works.
    """
    tags = probe(path).get("tags") or {}
    created = tags.get("creation_time") or tags.get("com.apple.quicktime.creationdate")
    if created:
        for fmt in _CREATION_FORMATS:
            try:
                parsed = datetime.strptime(created, fmt)
            except ValueError:
                continue
            # Normalize to naive local time so it can be compared with calendar events.
            if parsed.tzinfo is not None:
                parsed = parsed.astimezone().replace(tzinfo=None)
            return parsed

    stem = os.path.splitext(os.path.basename(path))[0]
    for fmt in _FILENAME_FORMATS:
        try:
            return datetime.strptime(stem, fmt)
        except ValueError:
            continue

    try:
        mtime = datetime.fromtimestamp(os.path.getmtime(path))
    except OSError:
        return None
    duration = probe_duration(path)
    # mtime marks when writing finished, so wind back over the recording itself.
    return mtime - timedelta(seconds=duration) if duration else mtime


def extract_audio(video_path, audio_path):
    """Extract mono 16 kHz PCM audio, the format whisper.cpp and sherpa-onnx expect."""
    video_path = os.path.abspath(video_path)
    subprocess.run(
        [
            ffmpeg_bin(),
            "-v",
            "error",
            "-i",
            video_path,
            # Pin the first audio stream. Voice Memos' .qta carries both a
            # normal AAC mix and an Apple Positional Audio (spatial) stream, and
            # letting ffmpeg choose "best" can select the spatial one.
            "-map",
            "0:a:0",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            audio_path,
            "-y",
        ],
        check=True,
        capture_output=True,
    )
    return audio_path


def has_video_stream(path):
    """True when the file carries a video stream."""
    try:
        result = subprocess.run(
            [
                ffprobe_bin(),
                "-v",
                "error",
                "-select_streams",
                "v",
                "-show_entries",
                "stream=index",
                "-of",
                "csv=p=0",
                os.path.abspath(path),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        return bool(result.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def cut_video(video_path, dest_path, start, end):
    """Copy the ``start``..``end`` slice of a video without re-encoding.

    Stream copy keeps this fast and lossless for multi-gigabyte recordings. The
    cut lands on the nearest keyframe at or before ``start``, which is fine for
    meeting-sized boundaries.
    """
    video_path = os.path.abspath(video_path)
    start = max(start, 0)
    cmd = [ffmpeg_bin(), "-v", "error", "-ss", f"{start:.3f}"]
    # Use an explicit duration rather than -to: with input seeking (-ss before
    # -i) a -to value is interpreted against the post-seek timeline, which makes
    # the resulting slice length ambiguous across ffmpeg versions.
    if end is not None:
        cmd += ["-t", f"{max(end - start, 0):.3f}"]
    # Map video (if any) and the first audio stream, rather than everything.
    # "-map 0" also grabs tracks that cannot be stream-copied: Voice Memos' .qta
    # carries an Apple Positional Audio stream and an mebx timed-metadata track,
    # and ffmpeg fails outright rather than skipping them.
    cmd += ["-i", video_path, "-c", "copy", "-map", "0:v?", "-map", "0:a:0", dest_path, "-y"]
    subprocess.run(cmd, check=True, capture_output=True)
    return dest_path
