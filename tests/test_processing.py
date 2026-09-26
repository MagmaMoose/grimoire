"""Tests for transcribe.processing: file moves, JSON output, LLM gating."""

import json

from transcribe import processing
from transcribe.processing import (
    _llm_configured,
    move_files_to_destination,
    process_video_file,
)

# --- _llm_configured --------------------------------------------------------


def test_llm_configured_claude(base_config):
    base_config["llm_provider"] = "claude"
    base_config["anthropic_api_key"] = ""
    assert _llm_configured(base_config) is False
    base_config["anthropic_api_key"] = "sk-ant"
    assert _llm_configured(base_config) is True


def test_llm_configured_openai(base_config):
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = ""
    assert _llm_configured(base_config) is False
    base_config["openai_api_key"] = "sk-oai"
    assert _llm_configured(base_config) is True


def test_llm_configured_default_provider(base_config):
    # No llm_provider key at all -> defaults to claude.
    cfg = {"anthropic_api_key": "sk-ant"}
    assert _llm_configured(cfg) is True


# --- move_files_to_destination ----------------------------------------------


def test_move_files_into_named_folder(tmp_path, base_config):
    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)

    video = tmp_path / "meeting.mov"
    video.write_bytes(b"video")
    transcript = tmp_path / "meeting_transcript.txt"
    transcript.write_text("transcript")
    summary = tmp_path / "meeting_summary.txt"
    summary.write_text("summary")

    moved = move_files_to_destination(str(video), str(transcript), str(summary), base_config)

    folder = dest / "meeting"
    assert folder.is_dir()
    assert (folder / "meeting.mov").exists()
    assert (folder / "meeting_transcript.txt").exists()
    assert (folder / "meeting_summary.txt").exists()
    # Originals were moved, not copied.
    assert not video.exists()
    assert not transcript.exists()
    assert not summary.exists()

    assert moved["video"] == str(folder / "meeting.mov")
    assert moved["transcript"] == str(folder / "meeting_transcript.txt")
    assert moved["summary"] == str(folder / "meeting_summary.txt")
    assert moved["folder"] == str(folder)


def test_move_files_handles_missing_summary(tmp_path, base_config):
    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)

    video = tmp_path / "v.mov"
    video.write_bytes(b"v")
    transcript = tmp_path / "v_transcript.txt"
    transcript.write_text("t")

    # summary_path is None -> skipped without error.
    moved = move_files_to_destination(str(video), str(transcript), None, base_config)
    assert "summary" not in moved
    assert (dest / "v" / "v.mov").exists()


def test_move_files_skips_missing_transcript(tmp_path, base_config):
    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)

    video = tmp_path / "v.mov"
    video.write_bytes(b"v")
    missing_transcript = tmp_path / "v_transcript.txt"  # not created

    moved = move_files_to_destination(str(video), str(missing_transcript), None, base_config)
    assert "transcript" not in moved
    assert (dest / "v" / "v.mov").exists()


# --- process_video_file -----------------------------------------------------


def _patch_pipeline(monkeypatch, transcript="hello transcript", config=None):
    """Stub transcription + Slack so process_video_file is pure-filesystem.

    Selects the legacy flat pipeline: these tests cover the single-transcript
    behaviour kept behind ``meeting_mode: false``. The meeting-aware pipeline is
    covered in test_meetings.py.
    """
    if config is not None:
        config["meeting_mode"] = False
    monkeypatch.setattr(processing, "transcribe_video", lambda v, c: transcript)
    slack_calls = []
    monkeypatch.setattr(
        processing,
        "send_slack_notification",
        lambda *a, **k: slack_calls.append((a, k)),
    )
    return slack_calls


def test_process_writes_transcript_and_moves(monkeypatch, tmp_path, base_config):
    _patch_pipeline(monkeypatch, config=base_config)
    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)
    base_config["slack_webhook_url"] = ""  # no slack
    base_config["anthropic_api_key"] = ""  # LLM disabled

    video = tmp_path / "clip.mov"
    video.write_bytes(b"data")

    process_video_file(str(video), base_config)

    folder = dest / "clip"
    assert (folder / "clip.mov").exists()
    assert (folder / "clip_transcript.txt").exists()
    assert (folder / "clip_transcript.txt").read_text() == "hello transcript"
    # No summary file because LLM is disabled.
    assert not (folder / "clip_summary.txt").exists()


def test_process_skips_llm_when_unconfigured(monkeypatch, tmp_path, base_config):
    _patch_pipeline(monkeypatch, config=base_config)
    called = []
    monkeypatch.setattr(processing, "summarize_with_openai", lambda *a, **k: called.append("sum"))
    monkeypatch.setattr(
        processing,
        "generate_title_description_with_openai",
        lambda *a, **k: called.append("td") or (None, None),
    )
    monkeypatch.setattr(
        processing,
        "extract_action_items_with_openai",
        lambda *a, **k: called.append("ai") or [],
    )

    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)
    base_config["anthropic_api_key"] = ""

    video = tmp_path / "c.mov"
    video.write_bytes(b"d")
    process_video_file(str(video), base_config)

    # No LLM function was invoked.
    assert called == []


def test_process_runs_llm_when_configured(monkeypatch, tmp_path, base_config):
    _patch_pipeline(monkeypatch, config=base_config)
    monkeypatch.setattr(processing, "summarize_with_openai", lambda *a, **k: "the summary")
    monkeypatch.setattr(
        processing,
        "generate_title_description_with_openai",
        lambda *a, **k: ("A Title", "A Desc"),
    )
    monkeypatch.setattr(processing, "extract_action_items_with_openai", lambda *a, **k: ["task 1"])

    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)
    base_config["anthropic_api_key"] = "sk-ant"

    video = tmp_path / "c.mov"
    video.write_bytes(b"d")
    process_video_file(str(video), base_config)

    folder = dest / "c"
    assert (folder / "c_summary.txt").read_text() == "the summary"


def test_process_sends_slack_when_configured(monkeypatch, tmp_path, base_config):
    slack_calls = _patch_pipeline(monkeypatch, config=base_config)
    monkeypatch.setattr(processing, "summarize_with_openai", lambda *a, **k: "s")
    monkeypatch.setattr(
        processing,
        "generate_title_description_with_openai",
        lambda *a, **k: ("T", "D"),
    )
    monkeypatch.setattr(processing, "extract_action_items_with_openai", lambda *a, **k: ["item"])

    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)
    base_config["anthropic_api_key"] = "sk-ant"
    base_config["slack_webhook_url"] = "https://hooks.slack.com/x"

    video = tmp_path / "c.mov"
    video.write_bytes(b"d")
    process_video_file(str(video), base_config)

    assert len(slack_calls) == 1
    args, _ = slack_calls[0]
    # send_slack_notification(video_name, folder, title, description, action_items, config)
    assert args[0] == "c.mov"
    assert args[2] == "T"
    assert args[3] == "D"
    assert args[4] == ["item"]


def test_process_writes_json_when_requested(monkeypatch, tmp_path, base_config):
    _patch_pipeline(monkeypatch, transcript="full transcript text", config=base_config)
    monkeypatch.setattr(processing, "summarize_with_openai", lambda *a, **k: "summary!")
    monkeypatch.setattr(
        processing,
        "generate_title_description_with_openai",
        lambda *a, **k: ("JTitle", "JDesc"),
    )
    monkeypatch.setattr(
        processing, "extract_action_items_with_openai", lambda *a, **k: ["ai1", "ai2"]
    )

    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)
    base_config["anthropic_api_key"] = "sk-ant"

    video = tmp_path / "c.mov"
    video.write_bytes(b"d")
    src_path = str(video)

    process_video_file(src_path, base_config, write_json=True)

    # JSON is written into the SAME destination folder as the moved
    # transcript/summary, not orphaned at the source path.
    result_json = dest / "c" / "c_result.json"
    assert result_json.exists()
    assert not (tmp_path / "c_result.json").exists()
    data = json.loads(result_json.read_text())
    assert data == {
        "title": "JTitle",
        "description": "JDesc",
        "transcript": "full transcript text",
        "summary": "summary!",
        "action_items": ["ai1", "ai2"],
        "source_file": src_path,
    }


def test_process_writes_json_at_source_when_no_destination(monkeypatch, tmp_path, base_config):
    _patch_pipeline(monkeypatch, transcript="t", config=base_config)
    # No destination configured -> JSON falls back to the source location.
    base_config["destination_directory"] = ""
    base_config["anthropic_api_key"] = ""

    video = tmp_path / "c.mov"
    video.write_bytes(b"d")

    process_video_file(str(video), base_config, write_json=True)

    result_json = tmp_path / "c_result.json"
    assert result_json.exists()
    data = json.loads(result_json.read_text())
    assert data["transcript"] == "t"
    assert data["source_file"] == str(video)


def test_process_no_json_by_default(monkeypatch, tmp_path, base_config):
    _patch_pipeline(monkeypatch, config=base_config)
    dest = tmp_path / "dest"
    dest.mkdir()
    base_config["destination_directory"] = str(dest)
    base_config["anthropic_api_key"] = ""

    video = tmp_path / "c.mov"
    video.write_bytes(b"d")
    process_video_file(str(video), base_config)

    assert not (tmp_path / "c_result.json").exists()
    assert not (dest / "c" / "c_result.json").exists()


def test_process_loads_config_when_none(monkeypatch, tmp_path):
    monkeypatch.setattr(processing, "transcribe_video", lambda v, c: "t")
    loaded = {}

    def fake_load():
        loaded["called"] = True
        return {
            "destination_directory": "",
            "llm_provider": "claude",
            "anthropic_api_key": "",
            "meeting_mode": False,
        }

    monkeypatch.setattr(processing, "load_config", fake_load)

    video = tmp_path / "c.mov"
    video.write_bytes(b"d")
    process_video_file(str(video), None)
    assert loaded["called"] is True


def test_write_meeting_outputs_can_leave_the_transcript_alone(tmp_path):
    """A meeting built from a folder's own transcript must not rewrite it."""
    from transcribe.processing import _write_meeting_outputs
    from transcribe.segments import Meeting, Segment

    folder = tmp_path / "m"
    folder.mkdir()
    original = "the original transcript, in whatever shape it came in"
    (folder / "transcript.txt").write_text(original)

    meeting = Meeting(index=1, start=0, end=10, segments=[Segment(start=0, end=10, text="hello")])
    _write_meeting_outputs(
        meeting,
        {"title": "T", "summary": "s"},
        folder,
        "/x/source.mov",
        None,
        {},
        split_video=False,
        write_transcript=False,
    )

    assert (folder / "transcript.txt").read_text() == original
    assert (folder / "notes.json").exists()


def test_write_meeting_outputs_writes_the_transcript_by_default(tmp_path):
    from transcribe.processing import _write_meeting_outputs
    from transcribe.segments import Meeting, Segment

    folder = tmp_path / "m"
    folder.mkdir()
    meeting = Meeting(index=1, start=0, end=10, segments=[Segment(start=0, end=10, text="hello")])
    _write_meeting_outputs(
        meeting, {"title": "T"}, folder, "/x/source.mov", None, {}, split_video=False
    )
    assert "hello" in (folder / "transcript.txt").read_text()
