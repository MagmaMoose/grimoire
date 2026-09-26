"""Tests for searching the library from the command line."""

import json

from transcribe import search


def make_meeting(root, name, lines, summary=""):
    folder = root / name
    folder.mkdir(parents=True)
    (folder / "notes.json").write_text(
        json.dumps(
            {
                "title": name,
                "notes": {"title": f"{name} notes", "summary": summary},
                "segments": [
                    {"timestamp": f"00:00:{index:02d}", "speaker": "Sam", "text": text}
                    for index, text in enumerate(lines)
                ],
            }
        )
    )
    return folder


def test_matching_lines_are_returned_with_their_meeting(tmp_path):
    make_meeting(tmp_path, "2026-09-01 Standup", ["We moved the BGP session", "Lunch"])
    make_meeting(tmp_path, "2026-09-02 Retro", ["Nothing relevant"])
    [(folder, title, hits, notes_only)] = search.search(tmp_path, "bgp")
    assert folder.name == "2026-09-01 Standup"
    assert title == "2026-09-01 Standup notes"
    assert hits == [("00:00:00", "Sam", "We moved the BGP session")]
    assert not notes_only


def test_a_mention_only_in_the_notes_still_counts(tmp_path):
    make_meeting(tmp_path, "m", ["nothing"], summary="Agreed the IPsec rollout")
    [(_, _, hits, notes_only)] = search.search(tmp_path, "ipsec")
    assert hits == []
    assert notes_only


def test_a_legacy_transcript_is_searched_too(tmp_path):
    folder = tmp_path / "Standup-20241120_095537-Meeting Recording"
    folder.mkdir()
    (folder / "transcript.txt").write_text("first line\nthe Kubernetes upgrade\n")
    [(_, _, hits, _)] = search.search(tmp_path, "kubernetes")
    assert hits == [("", None, "the Kubernetes upgrade")]


def test_run_prints_results(tmp_path, capsys):
    make_meeting(tmp_path, "m", ["We moved the BGP session"])
    assert search.run(["BGP"], {"destination_directory": str(tmp_path)}) == 0
    output = capsys.readouterr().out
    assert "1 meeting(s) mention 'BGP'" in output
    assert "[00:00:00] Sam: We moved the BGP session" in output


def test_run_with_no_hits_fails(tmp_path, capsys):
    assert search.run(["nothing"], {"destination_directory": str(tmp_path)}) == 1


def test_run_needs_words(capsys):
    assert search.run([], {"destination_directory": "/tmp"}) == 1
