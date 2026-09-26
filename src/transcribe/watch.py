"""Directory watching via watchdog."""

import os
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

from .processing import process_video_file

# How often the watcher looks for new Voice Memos, when that is switched on.
VOICE_MEMOS_POLL_SECONDS = 10 * 60
# After a permission failure, how long before trying again. Full Disk Access is
# granted by hand, so retrying every poll only repeats the same error.
VOICE_MEMOS_BLOCKED_SECONDS = 60 * 60

# How long a file's size must stay unchanged before it counts as finished.
STABLE_SECONDS = 10
STABLE_POLL_SECONDS = 5
# Give up waiting after this long rather than blocking the watcher forever.
STABLE_TIMEOUT_SECONDS = 12 * 60 * 60


def wait_until_stable(
    file_path,
    stable_seconds=STABLE_SECONDS,
    poll_seconds=STABLE_POLL_SECONDS,
    timeout=STABLE_TIMEOUT_SECONDS,
):
    """Block until ``file_path`` stops growing, then return True.

    A recorder creates its file at the *start* of the meeting and keeps writing
    for as long as it runs, so the creation event can arrive hours before the
    recording is complete. Waiting a fixed couple of seconds would transcribe an
    empty file.
    """
    deadline = time.monotonic() + timeout
    last_size = -1
    unchanged_for = 0.0

    while time.monotonic() < deadline:
        try:
            size = os.path.getsize(file_path)
        except OSError:
            return False  # deleted or moved while we waited

        if size == last_size and size > 0:
            unchanged_for += poll_seconds
            if unchanged_for >= stable_seconds:
                return True
        else:
            unchanged_for = 0.0
            last_size = size
        time.sleep(poll_seconds)

    print(f"Warning: {Path(file_path).name} still growing after {timeout / 3600:.0f}h", flush=True)
    return False


def watch_directory(directory, config):
    """Watch a directory for new video files and process them."""
    try:
        from watchdog.events import FileSystemEventHandler
        from watchdog.observers import Observer
    except ImportError:
        print("Error: watchdog library not installed. Install with: pip install watchdog")
        sys.exit(1)

    # Write startup message to log (for daemon visibility)
    startup_msg = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Transcribe daemon started\n"
    startup_msg += f"Watching: {directory}\n"
    startup_msg += f"Extensions: {', '.join(config.get('video_extensions', []))}\n"
    print(startup_msg, flush=True)

    # One heavy job at a time: a recording and a Voice Memo transcribing
    # together would each run at half speed and double the memory.
    busy = threading.Lock()

    class VideoHandler(FileSystemEventHandler):
        def __init__(self, config):
            self.config = config
            self.processing = set()

        def on_created(self, event):
            if event.is_directory:
                return

            file_path = event.src_path
            file_ext = Path(file_path).suffix.lower()

            # Check if it's a video file
            if file_ext in self.config.get("video_extensions", [".mov", ".mp4"]):
                # Avoid processing the same file multiple times
                if file_path in self.processing:
                    return

                self.processing.add(file_path)
                try:
                    print(f"Detected new file: {Path(file_path).name}", flush=True)
                    print("Waiting for the recording to finish writing...", flush=True)
                    if wait_until_stable(file_path) and Path(file_path).exists():
                        with busy:
                            process_video_file(file_path, self.config)
                finally:
                    self.processing.discard(file_path)

    print(f"Watching directory: {directory}", flush=True)
    print(f"Video extensions: {', '.join(config.get('video_extensions', []))}", flush=True)
    print("Press Ctrl+C to stop...\n", flush=True)
    sys.stdout.flush()

    event_handler = VideoHandler(config)
    observer = Observer()
    observer.schedule(event_handler, directory, recursive=False)
    observer.start()

    memos = VoiceMemoPoller(config, busy)
    try:
        while True:
            time.sleep(1)
            memos.poll()
    except KeyboardInterrupt:
        print("\nStopping watch...")
        observer.stop()
    observer.join()


class VoiceMemoPoller:
    """Imports new Voice Memos every few minutes, when ``voice_memos_auto_import`` is on.

    Kept out of the watchdog handler: Voice Memos writes into its own library,
    not the watch folder, so there is no file event to react to.
    """

    def __init__(self, config, busy, clock=time.monotonic):
        self.config = config
        self.busy = busy
        self.clock = clock
        self.next_check = 0.0

    def poll(self):
        if not self.config.get("voice_memos_auto_import", True):
            return None
        now = self.clock()
        if now < self.next_check:
            return None
        self.next_check = now + VOICE_MEMOS_POLL_SECONDS

        from .voicememos import VoiceMemosPermissionDenied, VoiceMemosUnavailable, import_new_memos

        try:
            with self.busy:
                return import_new_memos(self.config)
        except VoiceMemosPermissionDenied as e:
            self.next_check = now + VOICE_MEMOS_BLOCKED_SECONDS
            print(f"Voice Memos import paused for an hour: {e}", flush=True)
        except VoiceMemosUnavailable as e:
            # Not a permission: there is no Voice Memos library on this machine,
            # which polling will not change. Said once, not every hour.
            self.next_check = float("inf")
            print(f"Voice Memos import off: {e}", flush=True)
        except Exception as e:
            print(f"Warning: Voice Memos import failed ({type(e).__name__}: {e})", flush=True)
        return None
