"""File recordings that were processed but left behind in the watch folder.

The pipeline moves a recording out of the watch folder once its meetings are
written, but only on a clean run with ``move_source_video`` on. A run that
stopped early, a reprocess with ``--keep-source``, or a move that failed on a
busy iCloud folder all leave the original sitting where it was recorded, where
it looks exactly like something that has not been processed yet.

A recording counts as processed when some meeting's ``notes.json`` names it as
its ``source_file``. Matched on the file name, as the app does: the pipeline
records an absolute path, and the watch folder may have moved since.
"""

import json
import shutil
from pathlib import Path

from .media import MEDIA_SUFFIXES
from .processing import SOURCE_ARCHIVE, _unique_file


def _sources(destination):
    """Map each recorded source file name to the meeting folders it produced."""
    produced = {}
    root = Path(destination)
    if not root.is_dir():
        return produced
    for notes in root.glob("*/notes.json"):
        try:
            payload = json.loads(notes.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        source = payload.get("source_file") if isinstance(payload, dict) else None
        if source:
            produced.setdefault(Path(source).name, []).append(notes.parent)
    return produced


def leftovers(watch_directory, destination):
    """Recordings in the watch folder that already became meetings.

    Returns ``[(recording, [meeting folders])]``.
    """
    watch = Path(watch_directory)
    if not watch.is_dir():
        return []
    produced = _sources(destination)
    found = []
    for entry in sorted(watch.iterdir()):
        if entry.is_file() and entry.suffix.lower() in MEDIA_SUFFIXES and entry.name in produced:
            found.append((entry, sorted(produced[entry.name])))
    return found


def _repoint(folders, old, new):
    """Point each meeting's ``source_file`` at where the recording went."""
    for folder in folders:
        path = folder / "notes.json"
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(payload, dict) or Path(payload.get("source_file") or "").name != old.name:
            continue
        payload["source_file"] = str(new)
        path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def tidy(config, dry_run=False):
    """Move every processed recording out of the watch folder.

    A recording that became one meeting goes into that meeting's folder, as the
    pipeline would have put it. One that became several, or whose meeting
    folder already holds a file of that name, goes to the archive folder.
    Returns ``(moved, failed)``.
    """
    watch = config.get("watch_directory")
    destination = config.get("destination_directory")
    if not watch or not destination:
        print("✗ Both watch_directory and destination_directory need to be set.")
        return 0, 1

    moved = failed = 0
    found = leftovers(watch, destination)
    if not found:
        print(
            "Nothing to tidy: every recording in the watch folder is still waiting to be processed."
        )
        return 0, 0

    for recording, folders in found:
        if len(folders) == 1 and not (folders[0] / recording.name).exists():
            target_folder = folders[0]
        else:
            target_folder = Path(destination) / SOURCE_ARCHIVE
        target = _unique_file(target_folder, recording.name)
        if dry_run:
            print(f"Would move {recording.name} -> {target}")
            continue
        try:
            target_folder.mkdir(parents=True, exist_ok=True)
            shutil.move(str(recording), target)
        except OSError as e:
            print(f"✗ {recording.name}: {type(e).__name__}: {e}")
            failed += 1
            continue
        _repoint(folders, recording, target)
        print(f"✓ Moved {recording.name} -> {target}")
        moved += 1
    return moved, failed
