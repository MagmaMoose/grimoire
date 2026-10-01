import json
from datetime import date, datetime

import pytest

from transcribe import digest


def meeting(
    root,
    name,
    *,
    started=None,
    start=0.0,
    title="T",
    summary="S",
    tags=None,
    attendees=(),
    event=None,
    source="rec.mov",
    notes=True,
    duration=1800.0,
):
    folder = root / name
    folder.mkdir()
    payload = {
        "title": title,
        "start": start,
        "duration_seconds": duration,
        "attendees": list(attendees),
        "speakers": ["Kim"],
        "calendar_event": event,
        "notes": {
            "title": title,
            "summary": summary,
            "decisions": [{"title": "Use Kafka", "detail": "d", "status": "aligned"}],
            "next_steps": [{"owner": "Sam", "title": "Write the ADR", "detail": ""}],
        }
        if notes
        else None,
        "source_file": source,
        "recording_started_at": started,
    }
    (folder / "notes.json").write_text(json.dumps(payload), encoding="utf-8")
    if tags:
        (folder / "tags.json").write_text(json.dumps(tags), encoding="utf-8")
    return folder


@pytest.fixture
def library(tmp_path):
    meeting(
        tmp_path,
        "2026-09-14 1245 BU update",
        title="BU update",
        tags={"names": ["Business"], "fields": {"Company": "Acme"}},
        event={"title": "BU update", "attendees": ["Sam Jansen", "Kim"]},
    )
    meeting(
        tmp_path,
        "rec",
        started="2026-09-15T09:00:00",
        start=1800.0,
        title="Sprint review",
        tags={"fields": {"Company": "Acme"}},
        source="/x/Sprint-review.vtt",
    )
    meeting(
        tmp_path,
        "2026-09-16 1000 Other client",
        title="Other client",
        tags={"fields": {"Company": "Globex"}},
    )
    meeting(tmp_path, "Weekly-20260920_101500-Meeting Recording", title="Weekly", notes=False)
    meeting(tmp_path, "2026-08-01 0900 Too old", title="Too old")
    (tmp_path / "loose-file.txt").write_text("x")
    (tmp_path / "no-notes").mkdir()
    return tmp_path


def test_meeting_start_sources():
    from pathlib import Path

    assert digest.meeting_start(
        Path("x"), {"recording_started_at": "2026-09-15T09:00:00", "start": 90}
    ) == datetime(2026, 9, 15, 9, 1, 30)
    assert digest.meeting_start(Path("2026-09-14 1245 BU"), {}) == datetime(2026, 9, 14, 12, 45)
    assert digest.meeting_start(Path("2026-09-14 12-45-10 BU"), {}) == datetime(
        2026, 9, 14, 12, 45, 10
    )
    assert digest.meeting_start(Path("Weekly-20260920_101500-Meeting Recording"), {}) == (
        datetime(2026, 9, 20, 10, 15)
    )
    assert digest.meeting_start(Path("untitled"), {}) is None


def test_collect_by_date_and_filters(library):
    got = digest.collect(library, date(2026, 9, 11), date(2026, 10, 5))
    assert [m.title for m in got] == ["BU update", "Sprint review", "Other client", "Weekly"]
    assert got[1].start == datetime(2026, 9, 15, 9, 30)
    assert got[1].source == "transcript" and got[0].source == "recording"
    assert got[3].has_notes is False and got[3].title == "Weekly"

    acme = digest.collect(library, date(2026, 9, 11), date(2026, 10, 5), {"company": "acme"})
    assert [m.title for m in acme] == ["BU update", "Sprint review"]

    business = digest.collect(library, date(2026, 9, 1), date(2026, 9, 30), categories=["business"])
    assert [m.title for m in business] == ["BU update"]

    sam = digest.collect(library, date(2026, 9, 1), date(2026, 9, 30), attendee="sam jansen")
    assert [m.title for m in sam] == ["BU update"]
    assert digest.collect(library / "missing", date(2026, 9, 1), date(2026, 9, 30)) == []


def test_json_shape(library):
    got = digest.collect(library, date(2026, 9, 14), date(2026, 9, 14))
    data = digest.to_json(got, date(2026, 9, 14), date(2026, 9, 14), None)
    assert data["version"] == 1 and data["rollup"] is None
    (m,) = data["meetings"]
    assert m["start"] == "2026-09-14T12:45:00" and m["end"] == "2026-09-14T13:15:00"
    assert m["fields"] == {"Company": "Acme"}
    assert m["attendees"] == ["Sam Jansen", "Kim"]
    assert m["next_steps"][0]["owner"] == "Sam"


def test_markdown_with_and_without_a_rollup(library):
    got = digest.collect(library, date(2026, 9, 11), date(2026, 10, 5))
    plain = digest.to_markdown(got, date(2026, 9, 11), date(2026, 10, 5), None)
    assert plain.startswith("# Meetings 11 Sep to 05 Oct 2026 (4)")
    assert "## Mon 14 Sep 12:45 · BU update" in plain
    assert "No notes yet" in plain
    rolled = digest.to_markdown(
        got,
        date(2026, 9, 11),
        date(2026, 10, 5),
        {
            "summary": "A busy month.",
            "themes": [{"title": "Kafka", "detail": "Chosen.", "meetings": ["BU update"]}],
            "decisions": [{"text": "Use Kafka", "meeting": "BU update"}],
            "next_steps": [{"owner": "", "title": "Write the ADR", "meeting": "BU update"}],
            "open_questions": ["Who owns it?"],
        },
    )
    assert "## Overview" in rolled and "**[Unassigned]** Write the ADR" in rolled
    assert "- Who owns it?" in rolled


def test_rollup_reads_notes_not_transcripts(library, monkeypatch, base_config):
    seen = {}
    monkeypatch.setattr(digest, "is_configured", lambda config: True)

    def fake(config, system, user, schema, max_tokens):
        seen.update(user=user, schema=schema)
        return {"summary": "ok"}

    monkeypatch.setattr(digest, "complete_json", fake)
    got = digest.collect(library, date(2026, 9, 11), date(2026, 10, 5))
    assert digest.rollup(got, base_config) == {"summary": "ok"}
    assert "## BU update" in seen["user"] and "Weekly" not in seen["user"]
    assert "Next step [Sam]: Write the ADR" in seen["user"]
    assert seen["schema"] is digest.ROLLUP_SCHEMA


def test_rollup_skips_without_a_model(library, base_config):
    got = digest.collect(library, date(2026, 9, 11), date(2026, 10, 5))
    assert digest.rollup(got, base_config) is None


def test_run_json_to_a_file(library, base_config, tmp_path, capsys):
    base_config["destination_directory"] = str(library)
    out = tmp_path / "d.json"
    code = digest.run(
        [
            "--from=2026-09-11",
            "--to",
            "2026-10-05",
            "--field",
            "Company=Acme",
            "--json",
            f"--out={out}",
        ],
        base_config,
    )
    assert code == 0
    data = json.loads(out.read_text(encoding="utf-8"))
    assert [m["title"] for m in data["meetings"]] == ["BU update", "Sprint review"]
    assert "2 meetings written" in capsys.readouterr().out


def test_run_defaults_to_the_last_week(library, base_config, capsys, monkeypatch):
    class Today(date):
        @classmethod
        def today(cls):
            return date(2026, 9, 18)

    monkeypatch.setattr(digest, "date", Today)
    base_config["destination_directory"] = str(library)
    assert digest.run([], base_config) == 0
    out = capsys.readouterr().out
    assert "BU update" in out and "Weekly" not in out


@pytest.mark.parametrize(
    "args",
    [
        ["--from=14-09-2026"],
        ["--from=2026-09-20", "--to=2026-09-10"],
        ["--field", "Company"],
    ],
)
def test_run_rejects_bad_options(library, base_config, args):
    base_config["destination_directory"] = str(library)
    assert digest.run(args, base_config) == 1


def test_run_needs_a_library(base_config):
    base_config["destination_directory"] = ""
    assert digest.run([], base_config) == 1


def test_local_timezone_from_the_environment(monkeypatch):
    monkeypatch.setenv("TZ", "Europe/Amsterdam")
    assert digest.local_timezone() == "Europe/Amsterdam"
