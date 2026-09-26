"""Tests for rebuilding a meeting from a transcript that already exists."""

import json
from itertools import pairwise

import pytest

from transcribe import from_transcript
from transcribe.from_transcript import (
    find_transcript,
    generate_for_folder,
    generate_for_folders,
    parse_transcript,
    read_meeting,
    untimed_segments,
)

# This pipeline's own format: speaker headers, then stamped lines.
GROUPED = """Speaker 5:
[00:00:02] everybody can read it, except for the people in this room
[00:00:36] We would like the dev team to trigger the release

Speaker 12:
[00:00:54] Don't talk to me.

Speaker 5:
[00:01:04] We can change that.
"""

# Whisper's own output, which the older runs saved verbatim.
RANGED = """[00:00.000 --> 00:01.660]  take me a lot longer than expected,
[00:01.660 --> 00:03.580]  but I think we should be another three or four days
[01:02:03.000 --> 01:02:05.000]  and past the hour it stays correct
"""


# --- the speaker-grouped format ----------------------------------------------


def test_grouped_format_recovers_times_and_speakers():
    segments = parse_transcript(GROUPED)
    assert [s.start for s in segments] == [2.0, 36.0, 54.0, 64.0]
    assert [s.speaker for s in segments] == ["Speaker 5", "Speaker 5", "Speaker 12", "Speaker 5"]
    assert segments[2].text == "Don't talk to me."


def test_a_segment_ends_where_the_next_one_starts():
    """Neither format records an end for a grouped line."""
    segments = parse_transcript(GROUPED)
    assert segments[0].end == 36.0
    assert segments[1].end == 54.0


def test_the_last_segment_gets_a_real_duration():
    """A zero-length final segment would break anything measuring the meeting."""
    segments = parse_transcript(GROUPED)
    assert segments[-1].end > segments[-1].start


def test_unknown_speaker_is_not_treated_as_a_person():
    segments = parse_transcript("Unknown speaker:\n[00:00:01] hello\n")
    assert segments[0].speaker is None


def test_a_wrapped_line_joins_the_segment_above_it():
    text = "Speaker 1:\n[00:00:01] the first part\nand the wrapped remainder\n"
    segments = parse_transcript(text)
    assert len(segments) == 1
    assert segments[0].text == "the first part and the wrapped remainder"


# --- whisper's range format ---------------------------------------------------


def test_ranged_format_uses_the_recorded_end():
    segments = parse_transcript(RANGED)
    assert segments[0].start == 0.0
    assert segments[0].end == pytest.approx(1.66)
    assert segments[0].speaker is None


def test_ranged_format_handles_past_an_hour():
    """MM:SS and HH:MM:SS both appear, depending on the recording's length."""
    segments = parse_transcript(RANGED)
    assert segments[-1].start == pytest.approx(3723.0)


def test_timestamps_come_out_in_order():
    segments = parse_transcript(RANGED)
    assert [s.start for s in segments] == sorted(s.start for s in segments)


# --- prose with no timings ----------------------------------------------------


def test_untimed_prose_is_split_into_sentences():
    segments = untimed_segments("First thing. Second thing! Third thing?")
    assert [s.text for s in segments] == ["First thing.", "Second thing!", "Third thing?"]


def test_untimed_prose_is_spread_across_the_estimated_duration():
    segments = untimed_segments("One. Two. Three.")
    assert segments[0].start == 0
    assert all(a.end == b.start for a, b in pairwise(segments))


def test_untimed_prose_respects_a_known_duration():
    segments = untimed_segments("One. Two.", duration=100)
    assert segments[-1].end == pytest.approx(100)


@pytest.mark.parametrize("text", ["", "   ", None])
def test_nothing_in_means_nothing_out(text):
    assert parse_transcript(text) == []
    assert untimed_segments(text) == []


# --- finding and reading a folder ---------------------------------------------


def test_the_current_transcript_name_is_preferred(tmp_path):
    (tmp_path / "transcript.txt").write_text(GROUPED)
    (tmp_path / "old_transcription.txt").write_text(RANGED)
    assert find_transcript(tmp_path).name == "transcript.txt"


def test_the_legacy_transcript_name_is_found(tmp_path):
    (tmp_path / "A Meeting_transcription.txt").write_text(RANGED)
    assert find_transcript(tmp_path).name == "A Meeting_transcription.txt"


def test_a_folder_with_no_transcript(tmp_path):
    assert find_transcript(tmp_path) is None
    assert read_meeting(tmp_path) is None


def test_prose_falls_back_rather_than_failing(tmp_path):
    """An externally supplied transcript is one long line with no timings."""
    (tmp_path / "transcript.txt").write_text("Yes we are there. Okay thank you. So recapping.")
    meeting = read_meeting(tmp_path)
    assert meeting is not None
    assert len(meeting.segments) == 3


def test_the_title_falls_back_to_the_folder_name(tmp_path):
    folder = tmp_path / "2024-10-30 11-04-23 Align Linux Servers"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)
    assert read_meeting(folder).title == "Align Linux Servers"


def test_a_teams_folder_name_is_cleaned_up(tmp_path):
    folder = tmp_path / "Standup-20241120_095537-Meeting Recording"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)
    assert read_meeting(folder).title == "Standup"


def test_existing_context_is_carried_over(tmp_path):
    """Regenerating must not lose the calendar match a previous run worked out."""
    (tmp_path / "transcript.txt").write_text(GROUPED)
    (tmp_path / "notes.json").write_text(
        json.dumps(
            {
                "title": "Old title",
                "attendees": ["Arno", "Caleb"],
                "calendar_event": {"title": "Branching sync"},
                "notes": {"title": "Branching and release strategy"},
            }
        )
    )
    meeting = read_meeting(tmp_path)
    assert meeting.title == "Branching and release strategy"
    assert meeting.attendees == ["Arno", "Caleb"]
    assert meeting.calendar_event["title"] == "Branching sync"


def test_corrupt_notes_json_does_not_stop_the_read(tmp_path):
    (tmp_path / "transcript.txt").write_text(GROUPED)
    (tmp_path / "notes.json").write_text("{not json")
    assert read_meeting(tmp_path) is not None


# --- generating ---------------------------------------------------------------


@pytest.fixture
def config(tmp_path):
    return {
        "llm_provider": "claude",
        "anthropic_api_key": "sk-ant",
        "destination_directory": str(tmp_path),
    }


def test_generating_writes_every_output(monkeypatch, tmp_path, config):
    folder = tmp_path / "2026-08-27 1105 Branching"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)
    monkeypatch.setattr(
        from_transcript,
        "read_meeting",
        from_transcript.read_meeting,
    )
    import transcribe.notes as notes_mod

    monkeypatch.setattr(
        notes_mod,
        "complete_json",
        lambda *a, **k: {
            "title": "Branching strategy",
            "summary": "s",
            "sections": [],
            "details": [],
            "next_steps": [{"owner": "Arno", "title": "Do it", "detail": "d"}],
        },
    )
    notes = generate_for_folder(folder, config, name_speakers=False)
    assert notes["title"] == "Branching strategy"
    for name in ("notes.json", "notes.md", "notes.html", "transcript.txt", "summary.txt"):
        assert (folder / name).exists(), name


def test_generating_never_transcribes(monkeypatch, tmp_path, config):
    """The whole point: the audio is not touched."""
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)

    import transcribe.notes as notes_mod
    import transcribe.whisper as whisper_mod

    monkeypatch.setattr(
        whisper_mod,
        "transcribe_video_segments",
        lambda *a, **k: pytest.fail("must not transcribe"),
    )
    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: {"title": "T", "summary": "s"})
    assert generate_for_folder(folder, config, name_speakers=False) is not None


def test_no_transcript_generates_nothing(tmp_path, config):
    folder = tmp_path / "empty"
    folder.mkdir()
    assert generate_for_folder(folder, config) is None


def test_no_provider_generates_nothing(tmp_path):
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)
    assert generate_for_folder(folder, {"anthropic_api_key": ""}) is None


def test_llm_failure_writes_nothing(monkeypatch, tmp_path, config):
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)
    import transcribe.notes as notes_mod

    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: None)
    assert generate_for_folder(folder, config, name_speakers=False) is None
    assert not (folder / "notes.json").exists()


def test_a_run_over_several_folders_reports_per_folder(monkeypatch, tmp_path, config, capsys):
    good = tmp_path / "good"
    good.mkdir()
    (good / "transcript.txt").write_text(GROUPED)
    bare = tmp_path / "bare"
    bare.mkdir()

    import transcribe.notes as notes_mod

    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: {"title": "T", "summary": "s"})
    result = generate_for_folders([str(good), str(bare)], config)
    output = capsys.readouterr().out
    assert "no transcript to work from" in output
    assert result == 0  # one worked, so the run is not a failure


def test_no_folders_is_an_error(config):
    assert generate_for_folders([], config) == 1


def test_no_provider_for_a_run_is_an_error(tmp_path):
    assert generate_for_folders([str(tmp_path)], {"anthropic_api_key": ""}) == 1


# --- the source transcript is never destroyed --------------------------------


def test_prose_transcript_is_not_overwritten(monkeypatch, tmp_path, config):
    """The reconstruction invents speakers and timestamps; the original is gone.

    Writing it back also poisons the next run, which then reads the invented
    timings as though they were measured.
    """
    folder = tmp_path / "m1"
    folder.mkdir()
    original = "Yes we are there. Okay thank you. So recapping a bit of history."
    (folder / "transcript.txt").write_text(original)

    import transcribe.notes as notes_mod

    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: {"title": "T", "summary": "s"})
    generate_for_folder(folder, config, name_speakers=False)

    assert (folder / "transcript.txt").read_text() == original


def test_a_timed_transcript_is_not_rewritten_either(monkeypatch, tmp_path, config):
    """Re-rendering raw whisper output drops the end times it recorded."""
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text(RANGED)

    import transcribe.notes as notes_mod

    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: {"title": "T", "summary": "s"})
    generate_for_folder(folder, config, name_speakers=False)

    assert (folder / "transcript.txt").read_text() == RANGED


def test_the_other_outputs_are_still_written(monkeypatch, tmp_path, config):
    """Leaving the transcript alone must not skip the notes."""
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)

    import transcribe.notes as notes_mod

    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: {"title": "T", "summary": "s"})
    generate_for_folder(folder, config, name_speakers=False)

    for name in ("notes.json", "notes.md", "notes.html", "summary.txt"):
        assert (folder / name).exists(), name


# --- parsing edge cases that lose or invent data -----------------------------


def test_a_preamble_before_the_first_timestamp_is_kept():
    """Whatever was said before the first stamped line is still the meeting."""
    segments = parse_transcript("Some preamble here\n[00:00:05] the first stamped line\n")
    assert len(segments) == 1
    assert "Some preamble here" in segments[0].text
    assert "the first stamped line" in segments[0].text


def test_a_wrapped_line_ending_in_a_colon_is_not_a_speaker():
    """'as follows:' is a sentence, not a name, and must not be deleted."""
    segments = parse_transcript("Speaker 1:\n[00:00:01] the plan is\nas follows:\nfirst we ship\n")
    assert "as follows:" in segments[0].text
    assert segments[0].speaker == "Speaker 1"


@pytest.mark.parametrize(
    "header", ["Speaker 5", "Arno Bakker", "Caleb Sargeant", "Unknown speaker"]
)
def test_real_speaker_headers_still_work(header):
    segments = parse_transcript(f"{header}:\n[00:00:01] hello\n")
    expected = None if header.lower() == "unknown speaker" else header
    assert segments[0].speaker == expected


def test_a_long_lowercase_phrase_is_not_a_speaker():
    segments = parse_transcript(
        "Speaker 1:\n[00:00:01] one\nand then the whole team agreed the following:\n"
    )
    assert segments[0].speaker == "Speaker 1"
    assert "the whole team agreed" in segments[0].text


# --- the recording start is not the meeting start ----------------------------


def test_a_split_meetings_folder_date_is_not_the_recording_start(tmp_path):
    """The folder name is recording_start + meeting.start, so the offset comes
    back out. Rendering added it a second time and dated the meeting late."""
    from transcribe.from_transcript import _recording_start
    from transcribe.segments import Meeting, Segment

    meeting = Meeting(
        index=1,
        start=8511.0,
        end=8600.0,
        segments=[Segment(start=8511.0, end=8600.0, text="x")],
    )
    started = _recording_start("/x/2026-08-25 1156 Janeway hosting", {}, meeting)
    assert started.hour == 9 and started.minute == 34


def test_a_meeting_at_offset_zero_keeps_the_folder_time():
    from transcribe.from_transcript import _recording_start
    from transcribe.segments import Meeting

    meeting = Meeting(index=1, start=0.0, end=60.0, segments=[])
    started = _recording_start("/x/2026-08-25 1156 Janeway hosting", {}, meeting)
    assert started.hour == 11 and started.minute == 56


def test_a_recorded_start_in_notes_json_wins(tmp_path):
    """A previous run measured it; the folder name is only a fallback."""
    from transcribe.from_transcript import _recording_start
    from transcribe.segments import Meeting

    meeting = Meeting(index=1, start=8511.0, end=8600.0, segments=[])
    started = _recording_start(
        "/x/2026-08-25 1156 Janeway", {"recording_started_at": "2026-08-25T09:34:17"}, meeting
    )
    assert started.hour == 9 and started.minute == 34 and started.second == 17


# --- one bad folder must not stop a run --------------------------------------


def test_a_malformed_notes_json_does_not_abort_the_batch(monkeypatch, tmp_path, config, capsys):
    good = tmp_path / "good"
    good.mkdir()
    (good / "transcript.txt").write_text(GROUPED)
    bad = tmp_path / "bad"
    bad.mkdir()
    (bad / "transcript.txt").write_text(GROUPED)
    (bad / "notes.json").write_bytes(b"\xff\xfe not json and not utf-8")

    import transcribe.notes as notes_mod

    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: {"title": "T", "summary": "s"})
    result = generate_for_folders([str(bad), str(good)], config)
    assert result == 0
    assert (good / "notes.json").exists()


def test_timed_transcripts_are_marked_as_measured(tmp_path):
    (tmp_path / "transcript.txt").write_text(GROUPED)
    assert read_meeting(tmp_path).timings_are_measured is True


def test_prose_transcripts_are_marked_as_interpolated(tmp_path):
    (tmp_path / "transcript.txt").write_text("One thing. Another thing. A third.")
    assert read_meeting(tmp_path).timings_are_measured is False


def test_interpolated_timings_tell_the_model_not_to_cite_them(monkeypatch, tmp_path, config):
    """Otherwise the notes cite invented timestamps as though measured."""
    captured = {}
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text("One thing. Another thing. A third one here.")

    import transcribe.notes as notes_mod

    monkeypatch.setattr(
        notes_mod,
        "complete_json",
        lambda cfg, system, user, schema, **kw: (
            captured.update(user=user) or {"title": "T", "summary": "s"}
        ),
    )
    generate_for_folder(folder, config, name_speakers=False)
    assert "interpolated" in captured["user"].lower()


def test_measured_timings_are_not_disclaimed(monkeypatch, tmp_path, config):
    captured = {}
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)

    import transcribe.notes as notes_mod

    monkeypatch.setattr(
        notes_mod,
        "complete_json",
        lambda cfg, system, user, schema, **kw: (
            captured.update(user=user) or {"title": "T", "summary": "s"}
        ),
    )
    generate_for_folder(folder, config, name_speakers=False)
    assert "interpolated" not in captured["user"].lower()


# --- speakers already named are left alone -----------------------------------


def test_already_named_speakers_are_not_renamed(monkeypatch, tmp_path, config):
    """Re-running notes could rename a real person to the wrong one, with no
    way back to what the earlier run worked out."""
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text(
        "Arno Bakker:\n[00:00:01] hello\n\nCaleb Sargeant:\n[00:00:05] hi\n"
    )

    import transcribe.notes as notes_mod

    monkeypatch.setattr(
        notes_mod, "resolve_speaker_names", lambda *a, **k: pytest.fail("must not rename")
    )
    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: {"title": "T", "summary": "s"})
    assert generate_for_folder(folder, config) is not None


def test_anonymous_speakers_are_still_named(monkeypatch, tmp_path, config):
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "transcript.txt").write_text(GROUPED)

    called = {}
    import transcribe.notes as notes_mod

    monkeypatch.setattr(
        notes_mod, "resolve_speaker_names", lambda *a, **k: called.setdefault("yes", True) or {}
    )
    monkeypatch.setattr(notes_mod, "complete_json", lambda *a, **k: {"title": "T", "summary": "s"})
    generate_for_folder(folder, config)
    assert called.get("yes")


# --- source_file must be absolute and real -----------------------------------


def test_source_file_points_at_the_media_that_is_there(tmp_path):
    from transcribe.from_transcript import _source_reference

    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "recording.mov").write_bytes(b"x")
    reference = _source_reference(folder, {})
    assert reference.endswith("recording.mov")
    assert reference.startswith("/")


def test_a_stale_source_file_is_replaced_by_real_media(tmp_path):
    from transcribe.from_transcript import _source_reference

    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "recording.mov").write_bytes(b"x")
    reference = _source_reference(folder, {"source_file": "/gone/missing.mov"})
    assert reference.endswith("recording.mov")


def test_a_relative_source_file_is_resolved(tmp_path):
    from transcribe.from_transcript import _source_reference

    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "recording.mov").write_bytes(b"x")
    reference = _source_reference(folder, {"source_file": "recording.mov"})
    assert reference.startswith("/") and reference.endswith("recording.mov")


def test_a_still_valid_source_file_is_kept(tmp_path):
    from transcribe.from_transcript import _source_reference

    elsewhere = tmp_path / "Movies"
    elsewhere.mkdir()
    original = elsewhere / "original.mov"
    original.write_bytes(b"x")
    folder = tmp_path / "m1"
    folder.mkdir()
    assert _source_reference(folder, {"source_file": str(original)}) == str(original)
