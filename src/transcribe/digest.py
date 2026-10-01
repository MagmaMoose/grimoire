"""Many meetings at once: the notes of every meeting in a date range, and a rollup.

Each meeting was summarised when it was processed, so selecting and reading the
notes costs nothing. The rollup, a summary of the summaries, is one more model
call over those notes, never over the transcripts.

``--json`` prints a stable shape (``"version": 1``) that other tools read; the
catchup report builder is one. Times are naive local times, as everywhere in the
library, with the zone named alongside when it can be found.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

from .categorise import read_fields, read_tags
from .llm import complete_json, is_configured

TRANSCRIPT_SUFFIXES = (".vtt", ".docx", ".txt")
_TEAMS_NAME = re.compile(r"[-_](\d{8})_(\d{6})[-_]Meeting Recording$")

ROLLUP_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {
            "type": "string",
            "description": "Three to five sentences on what happened across these meetings.",
        },
        "themes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "detail": {"type": "string"},
                    "meetings": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["title", "detail", "meetings"],
            },
        },
        "decisions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "meeting": {"type": "string"}},
                "required": ["text", "meeting"],
            },
        },
        "next_steps": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "owner": {"type": "string"},
                    "title": {"type": "string"},
                    "meeting": {"type": "string"},
                },
                "required": ["owner", "title", "meeting"],
            },
        },
        "open_questions": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["summary", "themes", "decisions", "next_steps", "open_questions"],
}

ROLLUP_SYSTEM = """You combine the notes of several meetings into one digest for someone \
who missed all of them. Use only what the notes say; never invent a decision, owner or date. \
Group by theme rather than by meeting, merge repeats, and keep the most recent position when \
meetings disagree. Name the meeting each decision and next step came from."""


@dataclass
class DigestMeeting:
    folder: Path
    title: str
    start: datetime | None
    end: datetime | None
    attendees: list[str] = field(default_factory=list)
    speakers: list[str] = field(default_factory=list)
    categories: list[str] = field(default_factory=list)
    fields: dict[str, str] = field(default_factory=dict)
    summary: str = ""
    decisions: list[dict] = field(default_factory=list)
    next_steps: list[dict] = field(default_factory=list)
    calendar_title: str | None = None
    source: str = "recording"
    has_notes: bool = False

    def to_dict(self) -> dict:
        return {
            "folder": str(self.folder),
            "title": self.title,
            "start": self.start.isoformat() if self.start else None,
            "end": self.end.isoformat() if self.end else None,
            "attendees": self.attendees,
            "speakers": self.speakers,
            "categories": self.categories,
            "fields": self.fields,
            "summary": self.summary,
            "decisions": self.decisions,
            "next_steps": self.next_steps,
            "calendar_title": self.calendar_title,
            "source": self.source,
            "has_notes": self.has_notes,
        }


def meeting_start(folder: Path, payload: dict) -> datetime | None:
    """When the meeting began, from the recording's start or the folder name."""
    stamp = payload.get("recording_started_at")
    if stamp:
        try:
            return datetime.fromisoformat(stamp) + timedelta(
                seconds=float(payload.get("start") or 0)
            )
        except (TypeError, ValueError):
            pass
    name = folder.name
    for fmt, width in (("%Y-%m-%d %H%M", 15), ("%Y-%m-%d %H-%M-%S", 19), ("%Y-%m-%d", 10)):
        try:
            return datetime.strptime(name[:width], fmt)
        except ValueError:
            continue
    teams = _TEAMS_NAME.search(name)
    if teams:
        try:
            return datetime.strptime(teams[1] + teams[2], "%Y%m%d%H%M%S")
        except ValueError:
            pass
    return None


def _read(folder: Path) -> dict | None:
    try:
        payload = json.loads((folder / "notes.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def _matches_fields(have: dict[str, str], want: dict[str, str]) -> bool:
    low = {k.lower(): v.strip().lower() for k, v in have.items()}
    return all(low.get(k.lower()) == v.strip().lower() for k, v in want.items())


def collect(
    destination,
    start: date,
    end: date,
    fields: dict[str, str] | None = None,
    categories: list[str] | None = None,
    attendee: str | None = None,
) -> list[DigestMeeting]:
    """Every meeting from ``start`` to ``end`` inclusive that passes the filters, oldest first."""
    root = Path(destination)
    if not root.is_dir():
        return []
    want_categories = {c.strip().lower() for c in categories or []}
    who = (attendee or "").strip().lower()
    out: list[DigestMeeting] = []
    for folder in root.iterdir():
        if not folder.is_dir():
            continue
        payload = _read(folder)
        if payload is None:
            continue
        began = meeting_start(folder, payload)
        if not began or not (start <= began.date() <= end):
            continue
        tags = read_tags(folder)
        have_fields = read_fields(folder)
        if fields and not _matches_fields(have_fields, fields):
            continue
        if want_categories and not want_categories & {t.lower() for t in tags}:
            continue
        event = payload.get("calendar_event") or {}
        people = [*payload.get("attendees", []), *event.get("attendees", [])]
        speakers = payload.get("speakers") or []
        if who and not any(who in str(p).lower() for p in [*people, *speakers]):
            continue
        notes = payload.get("notes") or {}
        duration = float(payload.get("duration_seconds") or 0)
        source_file = str(payload.get("source_file") or "")
        out.append(
            DigestMeeting(
                folder=folder,
                title=notes.get("title") or payload.get("title") or folder.name,
                start=began,
                end=began + timedelta(seconds=duration) if duration else None,
                attendees=list(dict.fromkeys(str(p) for p in people)),
                speakers=[str(s) for s in speakers],
                categories=tags,
                fields=have_fields,
                summary=notes.get("summary") or "",
                decisions=[d for d in notes.get("decisions") or [] if isinstance(d, dict)],
                next_steps=[s for s in notes.get("next_steps") or [] if isinstance(s, dict)],
                calendar_title=event.get("title"),
                source="transcript"
                if source_file.lower().endswith(TRANSCRIPT_SUFFIXES)
                else "recording",
                has_notes=bool(notes),
            )
        )
    out.sort(key=lambda m: m.start or datetime.min)
    return out


def rollup(meetings: list[DigestMeeting], config) -> dict | None:
    """One summary of the summaries, or None without notes or a configured model."""
    noted = [m for m in meetings if m.has_notes]
    if not noted or not is_configured(config):
        return None
    blocks = []
    for m in noted:
        when = m.start.strftime("%a %d %b %H:%M") if m.start else "undated"
        lines = [f"## {m.title} ({when})", m.summary]
        lines += [f"- Decision: {d.get('title', '')}: {d.get('detail', '')}" for d in m.decisions]
        lines += [
            f"- Next step [{s.get('owner') or 'unassigned'}]: {s.get('title', '')}"
            for s in m.next_steps
        ]
        blocks.append("\n".join(lines))
    return complete_json(
        config,
        ROLLUP_SYSTEM,
        "Meeting notes:\n\n" + "\n\n".join(blocks),
        ROLLUP_SCHEMA,
        max_tokens=int(config.get("digest_max_tokens", 8000)),
    )


def local_timezone() -> str | None:
    """The IANA name of this machine's zone, where the system exposes it."""
    if os.environ.get("TZ"):
        return os.environ["TZ"]
    try:
        target = os.readlink("/etc/localtime")
    except OSError:
        return None
    marker = "zoneinfo/"
    return target.split(marker, 1)[1] if marker in target else None


def to_json(meetings, start: date, end: date, summary: dict | None) -> dict:
    return {
        "version": 1,
        "from": start.isoformat(),
        "to": end.isoformat(),
        "timezone": local_timezone(),
        "meetings": [m.to_dict() for m in meetings],
        "rollup": summary,
    }


def to_markdown(meetings, start: date, end: date, summary: dict | None) -> str:
    lines = [f"# Meetings {start:%d %b} to {end:%d %b %Y} ({len(meetings)})", ""]
    if summary:
        lines += ["## Overview", "", summary.get("summary", ""), ""]
        for theme in summary.get("themes", []):
            lines += [f"### {theme.get('title', '')}", "", theme.get("detail", ""), ""]
        if summary.get("decisions"):
            lines += ["### Decisions", ""]
            lines += [
                f"- {d.get('text', '')} ({d.get('meeting', '')})" for d in summary["decisions"]
            ]
            lines.append("")
        if summary.get("next_steps"):
            lines += ["### Next steps", ""]
            lines += [
                f"- **[{s.get('owner') or 'Unassigned'}]** {s.get('title', '')} "
                f"({s.get('meeting', '')})"
                for s in summary["next_steps"]
            ]
            lines.append("")
        if summary.get("open_questions"):
            lines += ["### Open questions", ""]
            lines += [f"- {q}" for q in summary["open_questions"]]
            lines.append("")
    for m in meetings:
        when = m.start.strftime("%a %d %b %H:%M") if m.start else "undated"
        lines += [f"## {when} · {m.title}", ""]
        lines.append(m.summary or "_No notes yet: run `transcribe notes` on this folder._")
        lines.append("")
        lines += [f"- Decision: {d.get('title', '')}" for d in m.decisions]
        lines += [
            f"- Next step [{s.get('owner') or 'unassigned'}]: {s.get('title', '')}"
            for s in m.next_steps
        ]
        if m.decisions or m.next_steps:
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _option(args, name):
    """``--name=value`` or ``--name value``; every occurrence."""
    values = []
    for i, arg in enumerate(args):
        if arg.startswith(f"--{name}="):
            values.append(arg.split("=", 1)[1])
        elif arg == f"--{name}" and i + 1 < len(args):
            values.append(args[i + 1])
    return values


def _parse_date(value: str) -> date:
    return datetime.strptime(value, "%Y-%m-%d").date()


def run(args, config) -> int:
    """``transcribe digest`` -- the notes of every meeting in a date range."""
    destination = config.get("destination_directory")
    if not destination:
        print("✗ No destination_directory configured.")
        return 1
    try:
        end = _parse_date(_option(args, "to")[-1]) if _option(args, "to") else date.today()
        if _option(args, "from"):
            start = _parse_date(_option(args, "from")[-1])
        else:
            days = float(_option(args, "since-days")[-1]) if _option(args, "since-days") else 7
            start = end - timedelta(days=days)
    except ValueError as e:
        print(f"✗ Dates are YYYY-MM-DD and days a number ({e})")
        return 1
    if end < start:
        print("✗ --to is before --from")
        return 1

    wanted: dict[str, str] = {}
    for pair in _option(args, "field"):
        key, sep, value = pair.partition("=")
        if not sep:
            print(f"✗ --field needs NAME=VALUE, got {pair!r}")
            return 1
        wanted[key.strip()] = value.strip()
    attendee = _option(args, "attendee")[-1] if _option(args, "attendee") else None

    meetings = collect(destination, start, end, wanted, _option(args, "category"), attendee)
    summary = rollup(meetings, config) if "--rollup" in args else None
    if "--json" in args:
        text = json.dumps(to_json(meetings, start, end, summary), indent=2, ensure_ascii=False)
    else:
        text = to_markdown(meetings, start, end, summary)
    out = _option(args, "out")
    if out:
        Path(out[-1]).expanduser().write_text(text, encoding="utf-8")
        print(f"✓ {len(meetings)} meetings written to {out[-1]}")
    else:
        print(text)
    return 0
