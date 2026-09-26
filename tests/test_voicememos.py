"""Tests for importing Voice Memos without filing one twice or moving the original."""

from datetime import datetime

import pytest

from transcribe import processing, voicememos
from transcribe.voicememos import (
    import_memos,
    import_new_memos,
    load_imported,
    mark_imported,
    memo_key,
    title_hint,
)


def memo(tmp_path, name="20260926 101010-ABCD.m4a", title="Budget call", transcript=None):
    audio = tmp_path / "Recordings" / name
    audio.parent.mkdir(parents=True, exist_ok=True)
    audio.write_bytes(b"audio")
    return {
        "title": title,
        "recorded_at": datetime(2026, 9, 26, 10, 10, 10),
        "duration": 60.0,
        "audio_path": str(audio),
        "transcript": transcript,
    }


@pytest.fixture
def processed(monkeypatch):
    """Record what the pipeline was handed, and fake a successful run."""
    calls = []

    def fake(path, config, title=None, **kwargs):
        from pathlib import Path

        calls.append({"path": path, "title": title, "existed": Path(path).exists()})
        return processing.EXIT_OK

    monkeypatch.setattr(processing, "process_video_file", fake)
    return calls


def test_the_original_is_never_handed_to_the_pipeline(tmp_path, processed):
    """The pipeline moves its source. Given the memo, it emptied Voice Memos."""
    item = memo(tmp_path)
    assert import_memos([item], {}) == (1, 0, 0)
    assert processed[0]["path"] != item["audio_path"]
    assert processed[0]["existed"]
    assert (tmp_path / "Recordings" / "20260926 101010-ABCD.m4a").exists()


def test_a_memo_is_imported_once(tmp_path, processed):
    item = memo(tmp_path)
    import_memos([item], {})
    assert import_memos([item], {}) == (0, 1, 0)
    assert len(processed) == 1


def test_force_imports_again(tmp_path, processed):
    item = memo(tmp_path)
    import_memos([item], {})
    assert import_memos([item], {}, force=True) == (1, 0, 0)


def test_a_failure_is_retried_next_time(tmp_path, monkeypatch):
    item = memo(tmp_path)
    monkeypatch.setattr(processing, "process_video_file", lambda *a, **k: processing.EXIT_FAILED)
    assert import_memos([item], {}) == (0, 0, 1)
    assert memo_key(item) not in load_imported()


def test_a_labelled_memo_titles_its_meeting(tmp_path, processed):
    import_memos([memo(tmp_path, title="Budget call")], {})
    assert processed[0]["title"] == "Budget call"


@pytest.mark.parametrize("title", ["New Recording", "New Recording 3", "Voice Memo 2026-09-26", ""])
def test_a_default_memo_name_is_not_a_title(title):
    assert title_hint({"title": title}) is None


def test_the_app_transcript_can_be_used_instead(tmp_path, monkeypatch):
    item = memo(tmp_path, transcript="We agreed the budget.")
    seen = {}
    monkeypatch.setattr(
        processing,
        "process_transcript",
        lambda audio, transcript, config, **k: seen.setdefault("transcript", transcript),
    )
    assert import_memos([item], {}, prefer_app=True) == (1, 0, 0)
    assert seen["transcript"] == "We agreed the budget."


def test_a_memo_with_neither_audio_nor_transcript_fails(tmp_path):
    item = {"title": "x", "recorded_at": None, "duration": None, "audio_path": None}
    item["transcript"] = None
    assert import_memos([item], {}) == (0, 0, 1)


def test_the_ledger_survives_a_reload(tmp_path):
    item = memo(tmp_path)
    mark_imported(item)
    assert load_imported()[memo_key(item)]["title"] == "Budget call"


def test_a_corrupt_ledger_reads_as_empty(private_config_dir):
    private_config_dir.mkdir(parents=True, exist_ok=True)
    (private_config_dir / voicememos.LEDGER_NAME).write_text("{not json")
    assert load_imported() == {}


def test_only_new_memos_are_imported(tmp_path, monkeypatch, processed):
    old = memo(tmp_path, name="old.m4a")
    new = memo(tmp_path, name="new.m4a")
    mark_imported(old)
    monkeypatch.setattr(voicememos, "list_memos", lambda since=None: [new, old])
    assert import_new_memos({}) == (1, 1, 0)
    assert len(processed) == 1


def test_nothing_new_imports_nothing(tmp_path, monkeypatch, processed):
    item = memo(tmp_path)
    mark_imported(item)
    monkeypatch.setattr(voicememos, "list_memos", lambda since=None: [item])
    assert import_new_memos({}) == (0, 1, 0)
    assert processed == []


def test_a_protected_library_is_a_permission_problem(monkeypatch, tmp_path):
    container = tmp_path / "container"
    container.mkdir()
    monkeypatch.setattr(voicememos, "CONTAINER", container)
    monkeypatch.setattr(voicememos.os, "access", lambda *a: False)
    with pytest.raises(voicememos.VoiceMemosPermissionDenied):
        voicememos._connect()
