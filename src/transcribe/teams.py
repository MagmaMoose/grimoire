"""Read a Microsoft Teams transcript (.vtt, .docx or copied text) into segments.

Some tenants switch off Graph access to meeting transcripts, so the only way to
get one is to download it from Teams or Stream by hand. Teams already names the
speakers and times every line, which is better than anything inferred from the
audio, so the import keeps both and skips whisper, diarisation and speaker naming.

Three shapes come out of Teams:

- WebVTT: cues with ``00:00:03.120 --> 00:00:05.400`` timing lines and the
  speaker in a ``<v Name>`` voice tag.
- .docx: a few header lines (title, date, duration), then repeated blocks of
  ``Name   0:03`` followed by what they said. Read with the standard library,
  since a .docx is a zip of XML.
- Text pasted from the transcript pane, in the same shape as the .docx.

Consecutive lines from one speaker are merged into a single segment, up to a
minute, because Teams cuts a sentence into several short cues and every segment
costs tokens later.
"""

from __future__ import annotations

import re
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from xml.etree import ElementTree

from .segments import Segment

SUFFIXES = (".vtt", ".docx", ".txt")
MERGE_GAP_SECONDS = 2.0
MERGE_MAX_SECONDS = 60.0

_CUE_TIMING = re.compile(
    r"^(?P<a>(?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s+-->\s+(?P<b>(?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})"
)
_VOICE = re.compile(r"<v(?:\.[^ >]*)?\s+([^>]+)>")
_TAG = re.compile(r"<[^>]+>")
# "Caleb Sargeant   0:03" or "Caleb Sargeant\t1:02:03"; a single space only for a
# short, capitalised name, so "we meet at 10:30" stays text.
_DOC_HEADER_WIDE = re.compile(r"^(?P<name>\S.*?)(?:\s{2,}|\t)(?P<ts>\d{1,2}(?::\d{2}){1,2})$")
_DOC_HEADER_TIGHT = re.compile(
    r"^(?P<name>(?:[A-Z][\w'.-]*)(?: [A-Za-z][\w'.-]*){0,4}) (?P<ts>\d{1,2}(?::\d{2}){1,2})$"
)
_SYSTEM_LINE = re.compile(r"\b(started|stopped) (transcription|recording)\b", re.IGNORECASE)

# Teams and Stream name downloads after the meeting, often with a timestamp.
_NAME_STAMP = re.compile(r"(?P<d>\d{8})[_-](?P<t>\d{6})")
_NAME_DATE = re.compile(r"(?P<d>\d{4}-\d{2}-\d{2})(?:[ _T](?P<h>\d{2})[:.\-h]?(?P<m>\d{2}))?")
_NAME_NOISE = re.compile(
    r"([-_ ]*\d{8}[_-]\d{6})?([-_ ]*(meeting )?(transcript|transcription|recording))*$",
    re.IGNORECASE,
)
_HEADER_DATE_FORMATS = (
    "%B %d, %Y, %I:%M%p",
    "%B %d, %Y, %I:%M %p",
    "%B %d, %Y %I:%M%p",
    "%d %B %Y, %H:%M",
    "%d %B %Y %H:%M",
    "%Y-%m-%d %H:%M",
    "%d-%m-%Y %H:%M",
)


@dataclass
class Imported:
    """A transcript read from a Teams export, ready for the notes pipeline."""

    path: Path
    segments: list[Segment] = field(default_factory=list)
    title: str | None = None
    recorded_at: datetime | None = None

    @property
    def speakers(self) -> list[str]:
        seen: dict[str, None] = {}
        for s in self.segments:
            if s.speaker:
                seen.setdefault(s.speaker, None)
        return list(seen)

    @property
    def duration(self) -> float:
        return self.segments[-1].end if self.segments else 0.0


def _seconds(stamp: str) -> float:
    parts = stamp.replace(",", ".").split(":")
    total = 0.0
    for part in parts:
        total = total * 60 + float(part)
    return total


def _merge(segments: list[Segment]) -> list[Segment]:
    out: list[Segment] = []
    for seg in segments:
        prev = out[-1] if out else None
        if (
            prev
            and prev.speaker == seg.speaker
            and seg.start - prev.end <= MERGE_GAP_SECONDS
            and seg.end - prev.start <= MERGE_MAX_SECONDS
        ):
            prev.end = max(prev.end, seg.end)
            prev.text = f"{prev.text} {seg.text}".strip()
        else:
            out.append(Segment(start=seg.start, end=seg.end, text=seg.text, speaker=seg.speaker))
    return out


def parse_vtt(text: str) -> list[Segment]:
    segments: list[Segment] = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n")):
        lines = [ln.strip() for ln in block.strip().split("\n") if ln.strip()]
        for i, line in enumerate(lines):
            timing = _CUE_TIMING.match(line)
            if not timing:
                continue
            body = " ".join(lines[i + 1 :])
            voice = _VOICE.search(body)
            words = re.sub(r"\s+", " ", _TAG.sub("", body)).strip()
            if words:
                segments.append(
                    Segment(
                        start=_seconds(timing["a"]),
                        end=_seconds(timing["b"]),
                        text=words,
                        speaker=voice.group(1).strip() if voice else None,
                    )
                )
            break
    return _merge(segments)


def _header(line: str, pattern: re.Pattern) -> tuple[str, float] | None:
    m = pattern.match(line)
    if m and len(m["name"].split()) <= 6 and not m["name"].rstrip().endswith((".", "?", "!")):
        return m["name"].strip(), _seconds(m["ts"])
    return None


def parse_lines(lines: list[str]) -> tuple[list[Segment], list[str]]:
    """Speaker blocks from .docx or pasted text, plus the header lines before them."""
    lines = [ln.strip() for ln in lines]
    # Decide the header shape once per file: a single-space "Name 0:03" is only
    # trusted when no line has the usual wide gap, so text ending in a time stays text.
    wide = any(_DOC_HEADER_WIDE.match(ln) for ln in lines)
    pattern = _DOC_HEADER_WIDE if wide else _DOC_HEADER_TIGHT
    preamble: list[str] = []
    blocks: list[tuple[str, float, list[str]]] = []
    for line in lines:
        if not line or _SYSTEM_LINE.search(line):
            continue
        head = _header(line, pattern)
        if head:
            blocks.append((head[0], head[1], []))
        elif blocks:
            blocks[-1][2].append(line)
        else:
            preamble.append(line)

    segments: list[Segment] = []
    for i, (name, start, words) in enumerate(blocks):
        if not words:
            continue
        nxt = blocks[i + 1][1] if i + 1 < len(blocks) else None
        text = " ".join(words)
        # The last block has no successor to end it; assume a speaking pace.
        end = nxt if nxt is not None and nxt > start else start + max(len(text.split()) / 2.5, 1)
        segments.append(Segment(start=start, end=end, text=text, speaker=name))
    return _merge(segments), preamble


def docx_lines(path: Path) -> list[str]:
    """Paragraph texts of a .docx, in order."""
    ns = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    with zipfile.ZipFile(path) as z:
        root = ElementTree.fromstring(z.read("word/document.xml"))
    lines = []
    for para in root.iter(f"{ns}p"):
        parts = []
        for node in para.iter():
            if node.tag == f"{ns}t" and node.text:
                parts.append(node.text)
            elif node.tag in (f"{ns}tab",):
                parts.append("\t")
            elif node.tag in (f"{ns}br", f"{ns}cr"):
                parts.append("\n")
        lines.extend("".join(parts).split("\n"))
    return lines


def _date_from_name(stem: str) -> datetime | None:
    m = _NAME_STAMP.search(stem)
    if m:
        try:
            return datetime.strptime(m["d"] + m["t"], "%Y%m%d%H%M%S")
        except ValueError:
            pass
    m = _NAME_DATE.search(stem)
    if m:
        try:
            day = datetime.strptime(m["d"], "%Y-%m-%d")
            return day.replace(hour=int(m["h"] or 0), minute=int(m["m"] or 0))
        except ValueError:
            pass
    return None


def _title_from_name(stem: str) -> str | None:
    title = _NAME_NOISE.sub("", stem)
    title = _NAME_DATE.sub("", title)
    title = re.sub(r"[_]+", " ", title).strip(" -_")
    return title or None


def _date_from_preamble(preamble: list[str]) -> datetime | None:
    for line in preamble[:4]:
        candidate = re.sub(r"\s+", " ", line).strip()
        for fmt in _HEADER_DATE_FORMATS:
            try:
                return datetime.strptime(candidate, fmt)
            except ValueError:
                continue
    return None


def read(path: str | Path) -> Imported:
    """Read one Teams transcript file. Raises ValueError when nothing usable is in it."""
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix not in SUFFIXES:
        raise ValueError(f"{path.name}: not a Teams transcript ({', '.join(SUFFIXES)})")
    preamble: list[str] = []
    if suffix == ".docx":
        try:
            segments, preamble = parse_lines(docx_lines(path))
        except (zipfile.BadZipFile, KeyError, ElementTree.ParseError) as e:
            raise ValueError(f"{path.name}: not a readable .docx ({e})") from e
    else:
        text = path.read_text(encoding="utf-8-sig", errors="replace")
        if suffix == ".vtt" or text.lstrip().startswith("WEBVTT"):
            segments = parse_vtt(text)
        else:
            segments, preamble = parse_lines(text.splitlines())
    if not segments:
        raise ValueError(f"{path.name}: no timed, attributed lines found")
    title = _title_from_name(path.stem)
    if preamble and (not title or title.lower() in ("transcript", "meeting transcript")):
        title = preamble[0]
    recorded_at = _date_from_name(path.stem) or _date_from_preamble(preamble)
    return Imported(path=path, segments=segments, title=title, recorded_at=recorded_at)


def run_import(args, config) -> int:
    """``transcribe import`` -- turn Teams transcript files into meetings with notes."""
    from .processing import process_transcript

    files = [a for a in args if not a.startswith("--") and Path(a).suffix.lower() in SUFFIXES]
    title_opt = [a.split("=", 1)[1] for a in args if a.startswith("--title=")]
    at_opt = [a.split("=", 1)[1] for a in args if a.startswith("--at=")]
    if not files:
        print("Usage: transcribe import <transcript.vtt|.docx|.txt> [more files]")
        print('       --title="Weekly sync"  name the meeting (default: from the file)')
        print('       --at="2026-09-14 12:45"  when it started (default: from the file)')
        return 1
    try:
        at = datetime.strptime(at_opt[-1], "%Y-%m-%d %H:%M") if at_opt else None
    except ValueError:
        print(f"✗ --at must look like 2026-09-14 12:45, got {at_opt[-1]!r}")
        return 1

    failed = 0
    for name in files:
        try:
            got = read(name)
        except (OSError, ValueError) as e:
            print(f"✗ {e}")
            failed += 1
            continue
        started = at or got.recorded_at
        if started is None:
            # The download's own time is usually the day of the meeting.
            started = datetime.fromtimestamp(got.path.stat().st_mtime)
            print(
                f"  Note: no date in {got.path.name}; using the file's time "
                f"({started:%Y-%m-%d %H:%M}). Pass --at to correct it."
            )
        print(
            f"  {len(got.segments)} segments, {len(got.speakers)} speakers: "
            f"{', '.join(got.speakers[:6])}"
        )
        process_transcript(
            None,
            None,
            config,
            title=title_opt[-1] if title_opt else got.title,
            recorded_at=started,
            segments=got.segments,
            source=str(got.path.resolve()),
        )
    return 1 if failed and failed == len(files) else 0
