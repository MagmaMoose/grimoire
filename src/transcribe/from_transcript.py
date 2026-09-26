"""Generate notes from a transcript that already exists.

Most of an existing library is meetings that were transcribed before the notes
pipeline existed. Re-running the whole pipeline on them means transcribing an
hour of audio again to produce something the folder already contains, and for
the older ones the audio may not even be there any more.

The saved transcripts carry real timestamps, so they can be parsed back into
segments and fed to the same notes generation the live pipeline uses. Nothing is
re-transcribed and nothing is approximated.

Two formats appear in the wild:

**This pipeline's own**, speaker-grouped::

    Speaker 5:
    [00:00:02] everybody can read it, except for
    [00:00:36] We would like the dev team to

**Raw whisper**, which the older runs saved verbatim::

    [00:00.000 --> 00:01.660]  take me a lot longer than expected,

Both are handled. The first also recovers who was speaking, which the second
never had.
"""

import re
from pathlib import Path

from .segments import Meeting, Segment

# "[00:00:02] text" or "[01:02:03] text"
_STAMPED_LINE = re.compile(r"^\[(\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)\]\s*(.*)$")
# "Speaker 5:" or "Arno Bakker:" -- a short line that is only a name and a colon.
#
# It has to start with a capital and stay under a handful of words, or a wrapped
# sentence that happens to end in a colon ("as follows:") is read as a speaker
# and deleted from the transcript.
_SPEAKER_HEADER = re.compile(r"^([A-Z][^\[\]:]{0,58}):\s*$")
_MAX_HEADER_WORDS = 5
# "[00:00.000 --> 00:01.660]  text", whisper's own output.
_RANGE_LINE = re.compile(
    r"^\[((?:\d{1,2}:)?\d{1,2}:\d{2}(?:\.\d+)?)\s*-->\s*((?:\d{1,2}:)?\d{1,2}:\d{2}(?:\.\d+)?)\]\s*(.*)$"
)


def _seconds(stamp):
    """Turn ``HH:MM:SS.mmm`` or ``MM:SS.mmm`` into seconds."""
    parts = stamp.split(":")
    try:
        values = [float(part) for part in parts]
    except ValueError:
        return None
    total = 0.0
    for value in values:
        total = total * 60 + value
    return total


def parse_transcript(text):
    """Parse a saved transcript into segments, or return [] if it is not one.

    Segment ends are inferred from the next segment's start, because neither
    format records an end for the speaker-grouped case. The last segment is
    given a nominal length rather than zero so it still has duration.
    """
    if not text or not text.strip():
        return []

    segments = []
    preamble = []
    speaker = None

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue

        ranged = _RANGE_LINE.match(line)
        if ranged:
            start, end, body = ranged.groups()
            start_seconds, end_seconds = _seconds(start), _seconds(end)
            if start_seconds is None or not body.strip():
                continue
            segments.append(
                Segment(
                    start=start_seconds,
                    end=end_seconds if end_seconds is not None else start_seconds,
                    text=body.strip(),
                    speaker=None,
                )
            )
            continue

        stamped = _STAMPED_LINE.match(line)
        if stamped:
            stamp, body = stamped.groups()
            start_seconds = _seconds(stamp)
            if start_seconds is None or not body.strip():
                continue
            segments.append(
                Segment(start=start_seconds, end=start_seconds, text=body.strip(), speaker=speaker)
            )
            continue

        header = _SPEAKER_HEADER.match(line)
        if header and len(header.group(1).split()) <= _MAX_HEADER_WORDS:
            speaker = header.group(1).strip()
            # "Unknown speaker" is this pipeline's placeholder for an
            # unattributed turn, not a person.
            if speaker.lower() in {"unknown speaker", "unknown", "speaker"}:
                speaker = None
            continue

        # A line that is neither stamped nor a header belongs to the segment
        # above it, which is how a wrapped long turn appears. Before the first
        # stamped line there is no segment yet, so it is held rather than
        # dropped -- a transcript with a preamble lost it entirely.
        if segments:
            segments[-1].text = f"{segments[-1].text} {line}".strip()
        else:
            preamble.append(line)

    # Anything said before the first timestamp belongs to the meeting too.
    if preamble and segments:
        segments[0].text = f"{' '.join(preamble)} {segments[0].text}".strip()

    # Close each segment at the next one's start.
    for index, segment in enumerate(segments[:-1]):
        if segment.end <= segment.start:
            segment.end = max(segments[index + 1].start, segment.start)
    if segments and segments[-1].end <= segments[-1].start:
        segments[-1].end = segments[-1].start + _tail_seconds(segments[-1].text)

    return segments


def _tail_seconds(text):
    """A plausible length for the final turn, from its word count."""
    return max(len(text.split()) / 150.0 * 60.0, 1.0)


def untimed_segments(text, duration=None):
    """Split prose into segments spread across the recording.

    The timings are interpolated, not measured. That is enough to order the
    transcript and to give the notes something to cite, but a seek from one of
    these lands near the passage rather than on it.
    """
    pieces = [piece.strip() for piece in re.split(r"(?<=[.!?])\s+", text or "") if piece.strip()]
    if not pieces:
        return []

    total = float(duration) if duration else 0.0
    if total <= 0:
        # Rough speaking pace, used only to give the segments an ordering.
        total = max(len(text.split()) / 150.0 * 60.0, float(len(pieces)))

    span = total / len(pieces)
    return [
        Segment(start=index * span, end=(index + 1) * span, text=piece)
        for index, piece in enumerate(pieces)
    ]


def find_transcript(folder):
    """The transcript in a meeting folder, whichever naming it uses."""
    folder = Path(folder)
    direct = folder / "transcript.txt"
    if direct.exists():
        return direct
    for candidate in sorted(folder.glob("*_transcription.txt")):
        return candidate
    for candidate in sorted(folder.glob("*_transcript.txt")):
        return candidate
    return None


def read_meeting(folder):
    """Build a Meeting from a folder's existing transcript, or None."""
    path = find_transcript(folder)
    if not path:
        return None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

    segments = parse_transcript(text)
    timed = bool(segments)
    if not segments:
        # A third format exists: plain prose with no timings at all, which is
        # what an externally supplied transcript looks like. Sentences spread
        # evenly still produce usable notes; the timestamps locate a passage
        # roughly rather than exactly, and nothing downstream claims otherwise.
        segments = untimed_segments(text)
    if not segments:
        return None

    meeting = Meeting(
        index=1,
        start=segments[0].start,
        end=segments[-1].end,
        segments=segments,
    )
    _apply_existing_context(folder, meeting)
    # Whether the timings are measured or interpolated decides what the notes
    # may claim about them.
    meeting.timings_are_measured = timed
    return meeting


def _apply_existing_context(folder, meeting):
    """Carry over the title, attendees and calendar event, if notes exist.

    Regenerating notes must not lose the calendar match that a previous run
    worked out, and a meeting that already knows who was invited produces far
    better attribution.
    """
    import json

    path = Path(folder) / "notes.json"
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            raise ValueError("notes.json is not an object")
    except (OSError, ValueError):
        # No previous notes: fall back to the folder name, minus its date
        # prefix, which is the best title available.
        meeting.title = _title_from_folder_name(Path(folder).name)
        return

    meeting.title = (payload.get("notes") or {}).get("title") or payload.get("title")
    meeting.attendees = payload.get("attendees") or []
    meeting.calendar_event = payload.get("calendar_event")
    if not meeting.title:
        meeting.title = _title_from_folder_name(Path(folder).name)


# "Speaker 5", "SPEAKER_01" -- a placeholder rather than a person.
_ANONYMOUS_SPEAKER = re.compile(r"^(speaker[\s_-]*\d+|unknown.*)$", re.IGNORECASE)

_DATE_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}[ T](?:\d{2}-\d{2}-\d{2}|\d{4})?\s*")
_TEAMS_SUFFIX = re.compile(r"[-_]\d{8}_\d{6}[-_]Meeting Recording$")


def _title_from_folder_name(name):
    """The folder name with its timestamp stripped."""
    trimmed = _TEAMS_SUFFIX.sub("", _DATE_PREFIX.sub("", name)).strip()
    return trimmed or name


def _recording_start(folder, payload, meeting=None):
    """When the *recording* started, from previous notes or the folder name.

    The folder name is not the recording's start: the pipeline builds it from
    ``recording_start + meeting.start``, so for a meeting cut out of a longer
    recording it names the moment that meeting began. Rendering then adds the
    offset a second time, and a meeting 2h21m into a recording was dated 2h21m
    too late -- in notes.md and, worse, written back into notes.json.
    """
    from datetime import datetime, timedelta

    stamp = (payload or {}).get("recording_started_at")
    if stamp:
        try:
            return datetime.fromisoformat(stamp)
        except ValueError:
            pass

    # Anything derived from the folder name has the meeting's own offset baked
    # in already, so it comes back out here.
    offset = timedelta(seconds=meeting.start) if meeting is not None else timedelta()

    name = Path(folder).name
    for fmt, width in (("%Y-%m-%d %H%M", 15), ("%Y-%m-%d %H-%M-%S", 19), ("%Y-%m-%d", 10)):
        try:
            return datetime.strptime(name[:width], fmt) - offset
        except ValueError:
            continue
    embedded = re.search(r"[-_](\d{8}_\d{6})[-_]", name)
    if embedded:
        try:
            return datetime.strptime(embedded.group(1), "%Y%m%d_%H%M%S") - offset
        except ValueError:
            pass
    return None


_MEDIA_SUFFIXES = {".mov", ".mp4", ".m4v", ".m4a", ".qta", ".wav", ".mp3", ".mkv", ".avi"}


def _source_reference(folder, payload):
    """What to record as the source file.

    Absolute, and pointing at something that exists. A previous run's value is
    kept only if the file is still there: a recording that has since been moved
    or deleted would otherwise be written back into notes.json indefinitely, and
    the app resolves that path to find the media to play.
    """
    folder = Path(folder).resolve()

    existing = (payload or {}).get("source_file")
    if existing:
        candidate = Path(existing)
        if not candidate.is_absolute():
            candidate = folder / candidate
        if candidate.exists():
            return str(candidate.resolve())

    media = sorted(entry for entry in folder.iterdir() if entry.suffix.lower() in _MEDIA_SUFFIXES)
    if media:
        return str(media[0].resolve())

    # Nothing to point at. The previous value is better than a path that was
    # never real, since it still records where the recording came from.
    return existing or str(folder / folder.name)


def generate_for_folder(folder, config, name_speakers=True):
    """Write notes for one folder from the transcript it already has.

    Returns the notes dict, or None when there was nothing to work with.
    """
    import json

    from .llm import is_configured
    from .notes import generate_notes
    from .processing import _write_meeting_outputs

    folder = Path(folder)
    meeting = read_meeting(folder)
    if meeting is None:
        return None
    if not is_configured(config):
        return None

    try:
        with open(folder / "notes.json", encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            payload = {}
    except (OSError, ValueError):
        payload = {}

    # Speaker naming only applies where the transcript recorded who was
    # talking, and only where those labels are still anonymous. A transcript
    # whose speakers were named on a previous run already holds real names, and
    # asking again can rename someone to the wrong person with no way back.
    already_named = any(
        speaker and not _ANONYMOUS_SPEAKER.match(speaker) for speaker in meeting.speakers()
    )
    if name_speakers and meeting.speakers() and not already_named:
        try:
            from .notes import resolve_speaker_names

            known = meeting.attendees or config.get("known_participants") or []
            resolve_speaker_names(meeting, config, known)
        except Exception as e:
            print(f"  Warning: could not name speakers ({type(e).__name__}: {e})")

    # Timestamps spread evenly across prose locate a passage roughly. Citing
    # them as if they were measured is the same mistake the Voice Memos path
    # already guards against.
    extra_context = (
        None
        if meeting.timings_are_measured
        else ("The timestamps in this transcript are interpolated, not measured. Do not cite them.")
    )
    notes = generate_notes(meeting, config, extra_context=extra_context)
    if not notes:
        return None

    meeting.title = notes.get("title") or meeting.title
    meeting.notes = notes

    _write_meeting_outputs(
        meeting,
        notes,
        folder,
        _source_reference(folder, payload),
        _recording_start(folder, payload, meeting),
        config,
        split_video=False,
        # The transcript in this folder is what the meeting was built from.
        # Rewriting it replaces the original with a reconstruction, and for a
        # prose transcript that reconstruction invents timestamps.
        write_transcript=False,
    )
    return notes


def generate_for_folders(folders, config):
    """Write notes for several folders, reporting per folder."""
    from .llm import is_configured

    if not folders:
        print("No meeting folders given.")
        return 1
    if not is_configured(config):
        print("✗ No LLM provider configured. Set an API key in the settings first.")
        return 1

    failures = 0
    for entry in folders:
        folder = Path(entry)
        if not folder.is_dir():
            print(f"✗ Not a folder: {entry}")
            failures += 1
            continue

        if find_transcript(folder) is None:
            print(f"· {folder.name}: no transcript to work from")
            failures += 1
            continue

        print(f"\n--- {folder.name} ---")
        try:
            notes = generate_for_folder(folder, config)
        except Exception as e:
            print(f"✗ {type(e).__name__}: {e}")
            failures += 1
            continue
        if notes:
            print(f"✓ {notes.get('title') or folder.name}")
            steps = notes.get("next_steps") or []
            if steps:
                print(f"  {len(steps)} next step(s)")
        else:
            print("✗ Notes generation failed")
            failures += 1

    return 1 if failures == len(folders) else 0
