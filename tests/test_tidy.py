"""Tests for filing processed recordings left behind in the watch folder."""

import json

from transcribe.tidy import leftovers, tidy


def meeting(root, name, source):
    folder = root / name
    folder.mkdir(parents=True)
    (folder / "notes.json").write_text(json.dumps({"source_file": str(source), "notes": None}))
    return folder


def setup(tmp_path):
    watch = tmp_path / "watch"
    dest = tmp_path / "dest"
    watch.mkdir()
    dest.mkdir()
    return watch, dest, {"watch_directory": str(watch), "destination_directory": str(dest)}


def test_only_processed_recordings_are_leftovers(tmp_path):
    watch, dest, _ = setup(tmp_path)
    done = watch / "2026-09-26 10-00-00.mov"
    done.write_bytes(b"x")
    (watch / "2026-09-26 11-00-00.mov").write_bytes(b"new")
    (watch / "notes.txt").write_text("not a recording")
    folder = meeting(dest, "2026-09-26 1000 Standup", done)
    assert leftovers(watch, dest) == [(done, [folder])]


def test_a_single_meeting_gets_its_recording(tmp_path):
    watch, dest, config = setup(tmp_path)
    recording = watch / "a.mov"
    recording.write_bytes(b"x")
    folder = meeting(dest, "2026-09-26 1000 Standup", recording)

    assert tidy(config) == (1, 0)
    assert not recording.exists()
    assert (folder / "a.mov").read_bytes() == b"x"
    # The app finds the media through source_file when it is not in the folder.
    assert json.loads((folder / "notes.json").read_text())["source_file"] == str(folder / "a.mov")


def test_a_split_recording_goes_to_the_archive(tmp_path):
    watch, dest, config = setup(tmp_path)
    recording = watch / "a.mov"
    recording.write_bytes(b"x")
    meeting(dest, "2026-09-26 1000 First", recording)
    meeting(dest, "2026-09-26 1100 Second", recording)

    assert tidy(config) == (1, 0)
    assert (dest / "Source recordings" / "a.mov").exists()


def test_an_existing_file_is_never_overwritten(tmp_path):
    watch, dest, config = setup(tmp_path)
    recording = watch / "a.mov"
    recording.write_bytes(b"new")
    folder = meeting(dest, "m", recording)
    (folder / "a.mov").write_bytes(b"clip already here")

    tidy(config)
    assert (folder / "a.mov").read_bytes() == b"clip already here"
    assert (dest / "Source recordings" / "a.mov").read_bytes() == b"new"


def test_a_dry_run_moves_nothing(tmp_path, capsys):
    watch, dest, config = setup(tmp_path)
    recording = watch / "a.mov"
    recording.write_bytes(b"x")
    meeting(dest, "m", recording)

    assert tidy(config, dry_run=True) == (0, 0)
    assert recording.exists()
    assert "Would move a.mov" in capsys.readouterr().out


def test_nothing_to_do(tmp_path, capsys):
    _, _, config = setup(tmp_path)
    assert tidy(config) == (0, 0)
    assert "Nothing to tidy" in capsys.readouterr().out


def test_both_folders_are_needed(capsys):
    assert tidy({"watch_directory": "/w"}) == (0, 1)
