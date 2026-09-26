"""Tests for the cross-process claim on a recording."""

import pytest

from transcribe import processing
from transcribe.locks import AlreadyClaimed, claim


def test_a_claim_is_exclusive(tmp_path):
    recording = tmp_path / "2026-09-26 14-00-00.mov"
    with claim(recording), pytest.raises(AlreadyClaimed), claim(recording):
        pass


def test_a_released_claim_can_be_taken_again(tmp_path):
    recording = tmp_path / "a.mov"
    with claim(recording):
        pass
    with claim(recording):
        pass


def test_claims_on_different_files_do_not_collide(tmp_path):
    with claim(tmp_path / "a.mov"), claim(tmp_path / "b.mov"):
        pass


def test_the_claim_is_released_when_the_block_raises(tmp_path):
    recording = tmp_path / "a.mov"
    with pytest.raises(ValueError), claim(recording):
        raise ValueError("boom")
    with claim(recording):
        pass


def test_locks_live_in_the_config_directory(tmp_path, private_config_dir):
    with claim(tmp_path / "a.mov"):
        assert list((private_config_dir / "locks").glob("*.lock"))


def test_a_claimed_recording_is_not_processed_twice(monkeypatch, tmp_path, capsys):
    recording = tmp_path / "a.mov"
    recording.write_bytes(b"x")
    monkeypatch.setattr(
        processing, "process_recording", lambda *a, **k: pytest.fail("must not process")
    )
    with claim(recording):
        status = processing.process_video_file(str(recording), {"meeting_mode": True})
    assert status == processing.EXIT_BUSY
    assert "already being processed" in capsys.readouterr().out


def test_a_crash_reports_failure_rather_than_success(monkeypatch, tmp_path):
    """The app runs this as a subprocess; exit 0 on a crash read as "finished"."""
    recording = tmp_path / "a.mov"
    recording.write_bytes(b"x")

    def explode(*args, **kwargs):
        raise RuntimeError("whisper fell over")

    monkeypatch.setattr(processing, "process_recording", explode)
    assert processing.process_video_file(str(recording), {}) == processing.EXIT_FAILED


def test_a_clean_run_reports_success(monkeypatch, tmp_path):
    recording = tmp_path / "a.mov"
    recording.write_bytes(b"x")
    seen = {}
    monkeypatch.setattr(
        processing, "process_recording", lambda *a, **k: seen.setdefault("title", k.get("title"))
    )
    status = processing.process_video_file(str(recording), {}, title="Budget call")
    assert status == processing.EXIT_OK
    assert seen["title"] == "Budget call"
