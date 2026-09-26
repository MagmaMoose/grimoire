"""Importing recordings and transcripts from the macOS Voice Memos app.

Voice Memos already transcribes on device, so a memo arrives with the expensive
part done. This module reads the app's library and hands the audio plus its
existing transcript to the rest of the pipeline, skipping Whisper entirely.

Two things shape the implementation:

**The library is protected.** It lives in a group container that needs Full Disk
Access, so the process reading it has to be granted that once in System Settings.

**The schema is Apple's and undocumented.** Column names have changed across
releases, and transcription is recent. Rather than hardcode names that may not
exist on a given macOS version, the tables are introspected and columns matched
by pattern. ``describe_library`` prints what was found, which is the fastest way
to see why an import came back empty.

The database is opened read-only and immutable. Nothing here writes to it, and
nothing here moves or deletes a recording: the pipeline files its source, so an
import hands it a copy and the memo stays playable in Voice Memos.

Each import is recorded in ``~/.transcribe/voicememos-imported.json``, which is
what lets the app and the watcher import new memos on their own without filing
the same memo twice.
"""

import json
import os
import plistlib
import re
import shutil
import sqlite3
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

from . import config as config_mod

CONTAINER = Path.home() / "Library/Group Containers/group.com.apple.VoiceMemos.shared"
RECORDINGS_DIR = CONTAINER / "Recordings"
DATABASE = RECORDINGS_DIR / "CloudRecordings.db"

# Core Data stores dates as seconds since 2001-01-01, like the rest of Apple's
# frameworks.
APPLE_EPOCH = datetime(2001, 1, 1)

# Column-name fragments, most specific first, for each field we want.
_PATH_HINTS = ("ZPATH", "ZLOCALPATH", "ZFILEPATH", "PATH")
# ZENCRYPTEDTITLE holds the raw "2026-08-27T09:05:55Z" default name, so the
# user's own label is preferred and that one is only a last resort.
_TITLE_HINTS = ("ZCUSTOMLABEL", "ZTITLE", "ZLABEL", "ZNAME", "ZENCRYPTEDTITLE")
_DATE_HINTS = ("ZDATE", "ZCREATIONDATE", "ZRECORDINGDATE", "ZSTARTDATE")
_DURATION_HINTS = ("ZDURATION", "ZLOCALDURATION")
_TRANSCRIPT_HINTS = ("TRANSCRIPTION", "TRANSCRIPT")


class VoiceMemosUnavailable(RuntimeError):
    """Raised when the Voice Memos library cannot be read."""


class VoiceMemosPermissionDenied(VoiceMemosUnavailable):
    """Raised when the library exists but this process may not read it.

    Separate from the general case because the fix is different: this one is a
    Full Disk Access grant, and the app offers to open that settings page.
    """


def _full_disk_access_hint():
    """Explain which app to grant Full Disk Access to."""
    from .permissions import grant_hint

    return "The Voice Memos library needs Full Disk Access.\n" + grant_hint(
        "Full Disk Access", needs_manual_add=True
    )


def _connect():
    """Open the Voice Memos database read-only, never touching Apple's copy."""
    if not CONTAINER.exists():
        raise VoiceMemosUnavailable(f"Voice Memos is not set up on this Mac ({CONTAINER} missing)")

    # The container is stat-able without Full Disk Access but not readable, so a
    # missing-looking database usually means the permission, not the app.
    if not os.access(CONTAINER, os.R_OK):
        raise VoiceMemosPermissionDenied(_full_disk_access_hint())
    if not DATABASE.exists():
        raise VoiceMemosPermissionDenied(
            f"no Voice Memos database at {DATABASE}.\n{_full_disk_access_hint()}"
        )
    try:
        return sqlite3.connect(f"file:{DATABASE}?mode=ro&immutable=1", uri=True)
    except sqlite3.Error as e:
        # sqlite cannot distinguish "denied" from "corrupt"; permission is far
        # and away the likelier cause here.
        raise VoiceMemosPermissionDenied(
            f"could not open the Voice Memos database.\n{_full_disk_access_hint()}"
        ) from e


def _tables(connection):
    rows = connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    return [row[0] for row in rows]


def _columns(connection, table):
    return [row[1] for row in connection.execute(f"PRAGMA table_info('{table}')").fetchall()]


def _pick(columns, hints):
    """Return the first column matching any hint, preferring exact matches."""
    upper = {column.upper(): column for column in columns}
    for hint in hints:
        if hint in upper:
            return upper[hint]
    for hint in hints:
        for name in upper:
            if hint in name:
                return upper[name]
    return None


def _recording_table(connection):
    """Find the table holding recordings, and the columns we care about."""
    candidates = [t for t in _tables(connection) if "RECORDING" in t.upper()]
    # Prefer the table that actually has a path column and some rows.
    best = None
    for table in candidates:
        columns = _columns(connection, table)
        path_column = _pick(columns, _PATH_HINTS)
        if not path_column:
            continue
        try:
            count = connection.execute(f"SELECT COUNT(*) FROM '{table}'").fetchone()[0]
        except sqlite3.Error:
            continue
        if best is None or count > best[1]:
            best = (table, count, columns, path_column)
    if best is None:
        raise VoiceMemosUnavailable(
            "no recordings table found; run 'transcribe voicememos --debug' to see the schema"
        )
    table, _, columns, path_column = best
    return {
        "table": table,
        "columns": columns,
        "path": path_column,
        "title": _pick(columns, _TITLE_HINTS),
        "date": _pick(columns, _DATE_HINTS),
        "duration": _pick(columns, _DURATION_HINTS),
        "transcript": _pick(columns, _TRANSCRIPT_HINTS),
    }


def _decode_transcript(value):
    """Turn whatever the transcript column holds into plain text.

    Apple has stored this as plain text, as a plist, and as an archived object
    depending on the release, so the shape is checked rather than assumed.
    """
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        return text or None
    if isinstance(value, (bytes, bytearray)):
        raw = bytes(value)
        if raw[:8] == b"bplist00":
            try:
                parsed = plistlib.loads(raw)
            except Exception:
                parsed = None
            if parsed is not None:
                return _text_from_plist(parsed)
        # Fall back to treating it as UTF-8 with the archiver noise stripped.
        text = raw.decode("utf-8", "ignore").strip()
        return text or None
    return None


def _text_from_plist(parsed):
    """Pull the longest string out of a decoded plist structure."""
    found = []

    def walk(node):
        if isinstance(node, str):
            found.append(node)
        elif isinstance(node, dict):
            for item in node.values():
                walk(item)
        elif isinstance(node, (list, tuple)):
            for item in node:
                walk(item)

    walk(parsed)
    if not found:
        return None
    # The transcript is by far the longest string in the structure.
    best = max(found, key=len).strip()
    return best or None


_ISO_DEFAULT_NAME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?$")


def _clean_title(value, recorded_at):
    """Return a usable title, ignoring Voice Memos' machine-generated default.

    An untitled memo is stored as an ISO timestamp, which makes a poor folder
    name and a worse meeting title. The LLM renames the meeting from its content
    anyway, so a readable placeholder is enough.
    """
    text = (value or "").strip()
    if text and not _ISO_DEFAULT_NAME.match(text):
        return text
    if recorded_at:
        return f"Voice Memo {recorded_at:%Y-%m-%d %H:%M}"
    return "Voice Memo"


def _resolve_audio(path_value):
    """Turn the stored path into an absolute file path, if the file exists."""
    if not path_value:
        return None
    candidate = Path(path_value)
    if candidate.is_absolute() and candidate.exists():
        return candidate
    for base in (RECORDINGS_DIR, CONTAINER):
        resolved = base / candidate.name
        if resolved.exists():
            return resolved
    return None


def _read_sidecar_transcript(audio_path):
    """Look for a transcript sidecar file alongside the audio file.

    Voice Memos stores transcripts beside the audio rather than in the DB on
    every macOS version tested. The sidecar shares the audio file's stem; this
    tries the extensions most commonly seen in the Recordings directory.
    """
    if not audio_path:
        return None
    audio = Path(audio_path)
    for ext in (".transcript", ".txt"):
        sidecar = audio.with_suffix(ext)
        if sidecar.exists():
            try:
                return _decode_transcript(sidecar.read_bytes())
            except OSError:
                pass
    return None


def list_memos(since=None, limit=None):
    """Return Voice Memos recordings, newest first.

    Each entry is a dict with ``title``, ``recorded_at``, ``duration``,
    ``audio_path`` and ``transcript`` (None when the memo has not been
    transcribed by the app).
    """
    with _connect() as connection:
        schema = _recording_table(connection)
        wanted = [schema["path"]]
        for key in ("title", "date", "duration", "transcript"):
            if schema[key]:
                wanted.append(schema[key])

        columns = ", ".join(f'"{name}"' for name in wanted)
        order = f' ORDER BY "{schema["date"]}" DESC' if schema["date"] else ""
        rows = connection.execute(f'SELECT {columns} FROM "{schema["table"]}"{order}').fetchall()
    connection.close()

    memos = []
    for row in rows:
        values = dict(zip(wanted, row, strict=False))
        recorded_at = None
        if schema["date"] and values.get(schema["date"]) is not None:
            try:
                recorded_at = APPLE_EPOCH + timedelta(seconds=float(values[schema["date"]]))
            except (TypeError, ValueError):
                recorded_at = None

        if since and recorded_at and recorded_at < since:
            continue

        audio = _resolve_audio(values.get(schema["path"]))
        audio_path = str(audio) if audio else None
        db_transcript = _decode_transcript(
            values.get(schema["transcript"]) if schema["transcript"] else None
        )
        memos.append(
            {
                "title": _clean_title(
                    values.get(schema["title"]) if schema["title"] else None, recorded_at
                ),
                "recorded_at": recorded_at,
                "duration": values.get(schema["duration"]) if schema["duration"] else None,
                "audio_path": audio_path,
                "transcript": db_transcript or _read_sidecar_transcript(audio_path),
            }
        )
        if limit and len(memos) >= limit:
            break
    return memos


def inspect_storage(limit=40):
    """Describe what actually sits in the Recordings directory.

    The transcript is not in CloudRecordings.db on any macOS version tested, so
    it has to live beside the audio. This reports the file types present and the
    most recent entries, which is what identifies the sidecar.
    """
    import collections

    if not RECORDINGS_DIR.exists():
        return {"directory": str(RECORDINGS_DIR), "error": "not found"}

    try:
        entries = sorted(RECORDINGS_DIR.rglob("*"), key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError as e:
        return {"directory": str(RECORDINGS_DIR), "error": str(e)}

    extensions = collections.Counter(
        (entry.suffix.lower() or "(no extension)") for entry in entries if entry.is_file()
    )
    recent = []
    for entry in entries[:limit]:
        try:
            size = entry.stat().st_size
        except OSError:
            size = -1
        recent.append(
            {
                "name": str(entry.relative_to(RECORDINGS_DIR)),
                "kind": "dir" if entry.is_dir() else "file",
                "size": size,
            }
        )
    return {
        "directory": str(RECORDINGS_DIR),
        "extensions": dict(extensions.most_common()),
        "recent": recent,
    }


def describe_library():
    """Return a description of the schema actually found, for troubleshooting."""
    with _connect() as connection:
        tables = _tables(connection)
        schema = _recording_table(connection)
        transcript_columns = [
            column
            for table in tables
            for column in _columns(connection, table)
            if any(hint in column.upper() for hint in _TRANSCRIPT_HINTS)
        ]
        count = connection.execute(f'SELECT COUNT(*) FROM "{schema["table"]}"').fetchone()[0]
    connection.close()

    return {
        "database": str(DATABASE),
        "tables": tables,
        "recording_table": schema["table"],
        "recording_count": count,
        "columns": schema["columns"],
        "resolved": {
            key: schema[key] for key in ("path", "title", "date", "duration", "transcript")
        },
        "transcript_columns_anywhere": transcript_columns,
    }


# --- Importing ----------------------------------------------------------------

LEDGER_NAME = "voicememos-imported.json"

# Voice Memos names an untitled memo "New Recording", "New Recording 2", and so
# on. That is no better a meeting title than the pipeline's own placeholder.
_DEFAULT_MEMO_TITLE = re.compile(r"^(new recording|voice memo)\b", re.IGNORECASE)


def _ledger_path():
    # Read at call time so tests can redirect CONFIG_DIR.
    return config_mod.CONFIG_DIR / LEDGER_NAME


def memo_key(memo):
    """A stable identity for a memo: its file in the Recordings directory.

    The file name is unique per memo and survives a rename in the app, which the
    title does not.
    """
    if memo.get("audio_path"):
        return Path(memo["audio_path"]).name
    recorded = memo.get("recorded_at")
    stamp = recorded.isoformat() if hasattr(recorded, "isoformat") else str(recorded)
    return f"{memo.get('title') or 'memo'}|{stamp}"


def load_imported():
    """Memos already imported, keyed by ``memo_key``."""
    try:
        data = json.loads(_ledger_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    imported = data.get("imported") if isinstance(data, dict) else None
    return imported if isinstance(imported, dict) else {}


def _save_imported(imported):
    path = _ledger_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    temporary.write_text(
        json.dumps({"imported": imported}, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.chmod(temporary, 0o600)
    # A rename, so a crash mid-write leaves the previous ledger rather than half
    # of one, and a half-written ledger would re-import everything.
    os.replace(temporary, path)


def mark_imported(memo, status="imported"):
    """Record that ``memo`` has been dealt with, so it is never imported again."""
    imported = load_imported()
    recorded = memo.get("recorded_at")
    imported[memo_key(memo)] = {
        "title": memo.get("title"),
        "recorded_at": recorded.isoformat() if hasattr(recorded, "isoformat") else None,
        "imported_at": datetime.now().isoformat(timespec="seconds"),
        "status": status,
    }
    _save_imported(imported)


def title_hint(memo):
    """The memo's own label, when the user gave it one."""
    title = (memo.get("title") or "").strip()
    if not title or _DEFAULT_MEMO_TITLE.match(title):
        return None
    return title


def _import_one(memo, config, prefer_app):
    """Run one memo through the pipeline. Returns True when it produced notes."""
    from .processing import EXIT_OK, process_transcript, process_video_file

    if prefer_app and memo["transcript"]:
        return bool(
            process_transcript(
                memo["audio_path"],
                memo["transcript"],
                config,
                title=memo["title"],
                recorded_at=memo["recorded_at"],
                duration=memo["duration"],
            )
        )

    if memo["audio_path"]:
        # The pipeline moves its source into the meeting folder. Pointed at the
        # memo itself, that took the file out of the Voice Memos library and
        # left the app a memo it could no longer play. It gets a copy instead.
        staging = Path(tempfile.mkdtemp(prefix="transcribe-memo-"))
        try:
            copy = staging / Path(memo["audio_path"]).name
            shutil.copy2(memo["audio_path"], copy)
            status = process_video_file(str(copy), config, title=title_hint(memo))
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        return status == EXIT_OK

    if memo["transcript"]:
        # No readable audio, so the app's transcript beats nothing.
        print(f"{memo['title']!r}: audio unreadable, using the Voice Memos transcript")
        return bool(
            process_transcript(
                None,
                memo["transcript"],
                config,
                title=memo["title"],
                recorded_at=memo["recorded_at"],
                duration=memo["duration"],
            )
        )

    print(f"Skipping {memo['title']!r}: no readable audio and no transcript")
    return False


def import_memos(memos, config, force=False, prefer_app=False):
    """Import every memo not imported before. Returns ``(imported, skipped, failed)``.

    A memo that fails is not recorded, so the next run tries it again. One that
    another process is importing right now is skipped, not waited for.
    """
    from .locks import AlreadyClaimed, claim

    imported = skipped = failed = 0
    for memo in memos:
        key = memo_key(memo)
        if not force and key in load_imported():
            skipped += 1
            continue
        try:
            with claim(memo.get("audio_path") or key):
                # Checked again under the claim: the other process may have
                # finished this memo while this one was busy with the last.
                if not force and key in load_imported():
                    skipped += 1
                    continue
                if _import_one(memo, config, prefer_app):
                    mark_imported(memo)
                    imported += 1
                else:
                    failed += 1
        except AlreadyClaimed:
            print(f"Skipping {memo['title']!r}: another transcribe process is importing it")
            skipped += 1
    return imported, skipped, failed


def import_new_memos(config, lookback_days=None):
    """Import memos from the last few days that have not been imported yet.

    The unattended path, for the app and the watcher. The window stops the first
    run from filing years of voice notes nobody asked to see as meetings.
    """
    days = float(lookback_days or config.get("voice_memos_lookback_days", 7))
    memos = list_memos(since=datetime.now() - timedelta(days=days))
    known = load_imported()
    fresh = [memo for memo in memos if memo_key(memo) not in known]
    if not fresh:
        return 0, len(memos), 0
    # Oldest first, so meetings are filed in the order they happened.
    fresh.sort(key=lambda memo: memo.get("recorded_at") or datetime.min)
    print(f"{len(fresh)} new Voice Memo(s) to import")
    imported, skipped, failed = import_memos(fresh, config)
    return imported, skipped + len(memos) - len(fresh), failed
