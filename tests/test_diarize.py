"""Tests for speaker attribution: cluster labelling and segment assignment."""

import io
import tarfile
import wave

import pytest

from transcribe.diarize import (
    _drop_micro_clusters,
    _safe_extract,
    assign_speakers,
    diarize_meeting,
    label_clusters,
    read_wav_window,
)
from transcribe.segments import Meeting, Segment


def make_segments(spans):
    return [Segment(start=s, end=e, text=t) for s, e, t in spans]


# --- label_clusters ---------------------------------------------------------


def test_label_clusters_orders_by_talk_time():
    turns = [(0, 2, 7), (2, 12, 3), (12, 13, 7)]
    # Cluster 3 speaks for 10s, cluster 7 for 3s.
    assert label_clusters(turns) == {3: "Speaker 1", 7: "Speaker 2"}


def test_label_clusters_on_empty_input():
    assert label_clusters([]) == {}


# --- _drop_micro_clusters ---------------------------------------------------


def test_drop_micro_clusters_removes_noise_clusters():
    turns = [(0, 30, 0), (30, 30.2, 1), (31, 61, 2), (61, 61.1, 3)]
    kept = _drop_micro_clusters(turns)
    assert {turn[2] for turn in kept} == {0, 2}


def test_drop_micro_clusters_keeps_largest_when_all_are_tiny():
    turns = [(0, 0.5, 0), (1, 1.2, 1)]
    kept = _drop_micro_clusters(turns)
    assert {turn[2] for turn in kept} == {0}


def test_drop_micro_clusters_on_empty_input():
    assert _drop_micro_clusters([]) == []


# --- assign_speakers --------------------------------------------------------


def test_assign_speakers_uses_maximum_overlap():
    """A segment straddling two turns goes to whichever covers more of it."""
    segments = make_segments([(0, 10, "first"), (10, 20, "second")])
    # Cluster 0 talks longest overall, so it becomes Speaker 1.
    turns = [(0, 9, 0), (9.5, 14, 1), (14, 20, 0)]
    assign_speakers(segments, turns)
    assert segments[0].speaker == "Speaker 1"  # 9s of cluster 0 vs 0.5s of cluster 1
    assert segments[1].speaker == "Speaker 1"  # 6s of cluster 0 vs 4s of cluster 1


def test_assign_speakers_leaves_unmatched_segments_unattributed():
    """A segment with no overlapping turn stays None rather than guessing."""
    segments = make_segments([(0, 10, "covered"), (500, 510, "no diarized turn here")])
    turns = [(0, 10, 0), (11, 30, 0)]
    assign_speakers(segments, turns)
    assert segments[0].speaker == "Speaker 1"
    assert segments[1].speaker is None


def test_assign_speakers_with_no_turns_is_a_no_op():
    segments = make_segments([(0, 10, "hello")])
    assign_speakers(segments, [])
    assert segments[0].speaker is None


def test_assign_speakers_splits_a_two_person_conversation():
    segments = make_segments([(0, 5, "a1"), (5, 10, "b1"), (10, 15, "a2"), (15, 20, "b2")])
    turns = [(0, 5, 0), (5, 10, 1), (10, 15, 0), (15, 20, 1)]
    assign_speakers(segments, turns)
    assert [s.speaker for s in segments] == [
        "Speaker 1",
        "Speaker 2",
        "Speaker 1",
        "Speaker 2",
    ]


# --- read_wav_window --------------------------------------------------------


def _write_wav(path, seconds, rate=16000):
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(b"\x01\x00" * int(seconds * rate))


def test_read_wav_window_reads_only_the_requested_slice(tmp_path):
    pytest.importorskip("numpy")
    wav = tmp_path / "audio.wav"
    _write_wav(wav, seconds=10)

    whole = read_wav_window(str(wav))
    window = read_wav_window(str(wav), start=2.0, end=5.0)

    assert len(whole) == 160_000
    assert len(window) == 48_000


def test_read_wav_window_clamps_past_end_of_file(tmp_path):
    pytest.importorskip("numpy")
    wav = tmp_path / "audio.wav"
    _write_wav(wav, seconds=2)
    assert len(read_wav_window(str(wav), start=1.0, end=99.0)) == 16_000


# --- diarize_meeting --------------------------------------------------------


def test_diarize_meeting_degrades_when_unavailable(monkeypatch):
    """A missing optional dependency must not fail the run."""
    import transcribe.diarize as diarize_mod

    def boom(*args, **kwargs):
        raise diarize_mod.DiarizationUnavailable("sherpa-onnx is not installed")

    monkeypatch.setattr(diarize_mod, "diarize_window", boom)
    meeting = Meeting(index=1, start=0, end=10, segments=make_segments([(0, 10, "hi")]))

    assert diarize_meeting(meeting, "/audio.wav", {}) is False
    assert meeting.segments[0].speaker is None


def test_diarize_window_reports_the_import_error(monkeypatch):
    import sys

    import transcribe.diarize as diarize_mod

    monkeypatch.setitem(sys.modules, "sherpa_onnx", None)
    with pytest.raises(diarize_mod.DiarizationUnavailable, match="import of sherpa_onnx halted"):
        diarize_mod.diarize_window("/audio.wav")


def test_diarize_meeting_survives_unexpected_errors(monkeypatch):
    import transcribe.diarize as diarize_mod

    monkeypatch.setattr(
        diarize_mod,
        "diarize_window",
        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("onnx exploded")),
    )
    meeting = Meeting(index=1, start=0, end=10, segments=make_segments([(0, 10, "hi")]))
    assert diarize_meeting(meeting, "/audio.wav", {}) is False


def test_diarize_meeting_assigns_speakers(monkeypatch):
    import transcribe.diarize as diarize_mod

    monkeypatch.setattr(diarize_mod, "diarize_window", lambda *a, **k: [(0, 5, 0), (5, 10, 1)] * 4)
    meeting = Meeting(index=1, start=0, end=10, segments=make_segments([(0, 5, "a"), (5, 10, "b")]))
    assert diarize_meeting(meeting, "/audio.wav", {}) is True
    assert meeting.segments[0].speaker != meeting.segments[1].speaker


# --- _safe_extract ----------------------------------------------------------


def _tar_with_member(name):
    """Build an in-memory tarball containing one file member called ``name``."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as tar:
        info = tarfile.TarInfo(name=name)
        info.size = 0
        tar.addfile(info, io.BytesIO(b""))
    buffer.seek(0)
    return tarfile.open(fileobj=buffer, mode="r")


def test_safe_extract_rejects_path_traversal(tmp_path):
    with (
        _tar_with_member("../escaped.onnx") as tar,
        pytest.raises(ValueError, match="Refusing to extract"),
    ):
        _safe_extract(tar, str(tmp_path))
    assert not (tmp_path.parent / "escaped.onnx").exists()


def test_safe_extract_allows_normal_members(tmp_path):
    with _tar_with_member("model/model.onnx") as tar:
        _safe_extract(tar, str(tmp_path))
    assert (tmp_path / "model" / "model.onnx").exists()
