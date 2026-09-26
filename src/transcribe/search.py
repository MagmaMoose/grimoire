"""Search every meeting's transcript and notes from the command line.

The same question the app's search box answers: which meetings mention this,
and where. Plain substring matching, case-insensitive, like the app, so the two
agree on what counts as a hit.
"""

import json
from pathlib import Path

from .from_transcript import find_transcript


def _meeting_lines(folder):
    """``(title, [(timestamp, speaker, text)], extra text)`` for one folder."""
    try:
        payload = json.loads((folder / "notes.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        payload = None

    if isinstance(payload, dict):
        notes = payload.get("notes") or {}
        title = notes.get("title") or payload.get("title") or folder.name
        lines = [
            (segment.get("timestamp") or "", segment.get("speaker"), segment.get("text") or "")
            for segment in payload.get("segments") or []
            if isinstance(segment, dict)
        ]
        extra = [notes.get("summary") or ""]
        extra += [
            f"{s.get('heading', '')} {s.get('body', '')}" for s in notes.get("sections") or []
        ]
        extra += [
            f"{d.get('title', '')} {d.get('detail', '')}" for d in notes.get("decisions") or []
        ]
        extra += [
            f"{n.get('title', '')} {n.get('detail', '')}" for n in notes.get("next_steps") or []
        ]
        return title, lines, extra

    transcript = find_transcript(folder)
    if transcript is None:
        return None
    try:
        text = transcript.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    lines = [("", None, line.strip()) for line in text.splitlines() if line.strip()]
    return folder.name, lines, []


def search(destination, query, per_meeting=4):
    """Meetings mentioning ``query``, newest first: ``[(folder, title, hits, other)]``.

    ``hits`` are matching transcript lines; ``other`` is True when only the
    notes mention it.
    """
    needle = query.strip().lower()
    root = Path(destination)
    if not needle or not root.is_dir():
        return []

    results = []
    for folder in sorted((p for p in root.iterdir() if p.is_dir()), reverse=True):
        found = _meeting_lines(folder)
        if found is None:
            continue
        title, lines, extra = found
        hits = [line for line in lines if needle in line[2].lower()][:per_meeting]
        in_notes = any(needle in text.lower() for text in extra) or needle in title.lower()
        if hits or in_notes:
            results.append((folder, title, hits, not hits))
    return results


def run(args, config):
    """``transcribe search <query>``."""
    words = [arg for arg in args if not arg.startswith("--")]
    if not words:
        print("Usage: transcribe search <words to find>")
        return 1
    destination = config.get("destination_directory")
    if not destination:
        print("✗ No destination_directory configured.")
        return 1

    query = " ".join(words)
    results = search(destination, query)
    if not results:
        print(f"No meeting mentions {query!r}.")
        return 1
    print(f"{len(results)} meeting(s) mention {query!r}\n")
    for folder, title, hits, notes_only in results:
        print(f"{folder.name}")
        if title != folder.name:
            print(f"  {title}")
        for timestamp, speaker, text in hits:
            who = f"{speaker}: " if speaker else ""
            stamp = f"[{timestamp}] " if timestamp else ""
            print(f"    {stamp}{who}{text[:160]}")
        if notes_only:
            print("    (in the notes)")
        print()
    return 0
