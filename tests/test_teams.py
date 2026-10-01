import zipfile
from datetime import datetime

import pytest

from transcribe import teams

VTT = """WEBVTT

0f8a1c2d-1/12-0
00:00:03.120 --> 00:00:05.400
<v Alex Writer>Good morning, everyone.</v>

0f8a1c2d-1/13-0
00:00:05.900 --> 00:00:08.000
<v Alex Writer>Let's start with the cluster.</v>

0f8a1c2d-1/14-0
00:00:09.000 --> 00:00:12.500
<v Sam Jansen>The upgrade went
through last night.</v>

NOTE a note block that is not a cue

00:01:02.000 --> 00:01:04.000
No voice tag here
"""

DOC_LINES = [
    "Weekly platform sync",
    "September 14, 2026, 10:45AM",
    "15m 3s",
    "Alex Writer started transcription",
    "Alex Writer   0:03",
    "Good morning, everyone.",
    "Sam Jansen   0:10",
    "The upgrade went through.",
    "We meet again at 10:30",
    "Alex Writer   1:02",
    "Thanks.",
]


def test_vtt_keeps_speakers_and_times_and_merges_short_cues():
    segs = teams.parse_vtt(VTT)
    assert [(s.speaker, s.text) for s in segs] == [
        ("Alex Writer", "Good morning, everyone. Let's start with the cluster."),
        ("Sam Jansen", "The upgrade went through last night."),
        (None, "No voice tag here"),
    ]
    assert (segs[0].start, segs[0].end) == (3.12, 8.0)
    assert segs[2].start == 62.0


def test_vtt_does_not_merge_across_a_long_pause_or_a_minute():
    text = (
        "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v A>one</v>\n\n"
        "00:00:09.000 --> 00:00:10.000\n<v A>two</v>\n\n"
        "00:00:10.500 --> 00:01:30.000\n<v A>three</v>\n"
    )
    assert [s.text for s in teams.parse_vtt(text)] == ["one", "two", "three"]


def test_docx_shaped_lines():
    segs, preamble = teams.parse_lines(DOC_LINES)
    assert preamble == ["Weekly platform sync", "September 14, 2026, 10:45AM", "15m 3s"]
    assert [(s.speaker, s.start, s.end) for s in segs] == [
        ("Alex Writer", 3.0, 10.0),
        ("Sam Jansen", 10.0, 62.0),
        ("Alex Writer", 62.0, 63.0),
    ]
    # A text line ending in a time is not mistaken for a speaker.
    assert segs[1].text == "The upgrade went through. We meet again at 10:30"


def test_single_space_headers_when_the_file_has_no_wide_ones():
    segs, _ = teams.parse_lines(["Alex Writer 0:03", "Hello.", "Sam Jansen 0:07", "Hi."])
    assert [s.speaker for s in segs] == ["Alex Writer", "Sam Jansen"]


def _docx(path, lines):
    body = "".join(
        f'<w:p><w:r><w:t xml:space="preserve">{line.split(chr(9))[0]}</w:t>'
        + (f"<w:tab/><w:t>{line.split(chr(9))[1]}</w:t>" if "\t" in line else "")
        + "</w:r></w:p>"
        for line in lines
    )
    xml = (
        '<?xml version="1.0"?><w:document xmlns:w='
        '"http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body>{body}</w:body></w:document>"
    )
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("word/document.xml", xml)


def test_read_docx(tmp_path):
    path = tmp_path / "Weekly platform sync.docx"
    _docx(
        path,
        [
            "Weekly platform sync",
            "September 14, 2026, 10:45AM",
            "Alex Writer\t0:03",
            "Morning.",
            "Sam Jansen\t0:10",
            "Done.",
        ],
    )
    got = teams.read(path)
    assert got.title == "Weekly platform sync"
    assert got.recorded_at == datetime(2026, 9, 14, 10, 45)
    assert got.speakers == ["Alex Writer", "Sam Jansen"]
    assert got.duration > 10


def test_read_vtt_takes_title_and_time_from_the_file_name(tmp_path):
    path = tmp_path / "Sprint review-20260914_093000-Meeting Transcript.vtt"
    path.write_text(VTT, encoding="utf-8")
    got = teams.read(path)
    assert got.title == "Sprint review"
    assert got.recorded_at == datetime(2026, 9, 14, 9, 30)


def test_read_iso_dated_text(tmp_path):
    path = tmp_path / "Planning 2026-09-15 1100.txt"
    path.write_text("\n".join(DOC_LINES[3:]), encoding="utf-8")
    got = teams.read(path)
    assert got.title == "Planning"
    assert got.recorded_at == datetime(2026, 9, 15, 11, 0)


@pytest.mark.parametrize(
    ("name", "content"),
    [
        ("notes.pdf", "x"),
        ("empty.vtt", "WEBVTT\n\n"),
        ("broken.docx", "not a zip"),
    ],
)
def test_read_refuses_what_it_cannot_use(tmp_path, name, content):
    path = tmp_path / name
    path.write_text(content, encoding="utf-8")
    with pytest.raises(ValueError):
        teams.read(path)


def test_run_import_hands_measured_segments_to_the_pipeline(tmp_path, monkeypatch, base_config):
    seen = []
    monkeypatch.setattr(
        "transcribe.processing.process_transcript",
        lambda audio, transcript, config, **kw: seen.append(kw) or [],
    )
    path = tmp_path / "Sprint review-20260914_093000-Meeting Transcript.vtt"
    path.write_text(VTT, encoding="utf-8")
    assert teams.run_import([str(path), "--title=Review"], base_config) == 0
    (kw,) = seen
    assert kw["title"] == "Review"
    assert kw["recorded_at"] == datetime(2026, 9, 14, 9, 30)
    assert kw["segments"][0].speaker == "Alex Writer"
    assert kw["source"].endswith(".vtt")


def test_run_import_falls_back_to_the_file_time(tmp_path, monkeypatch, base_config, capsys):
    seen = []
    monkeypatch.setattr(
        "transcribe.processing.process_transcript",
        lambda audio, transcript, config, **kw: seen.append(kw) or [],
    )
    path = tmp_path / "transcript.vtt"
    path.write_text(VTT, encoding="utf-8")
    assert teams.run_import([str(path)], base_config) == 0
    assert seen[0]["recorded_at"] is not None
    assert "Pass --at" in capsys.readouterr().out


def test_run_import_errors(tmp_path, base_config, capsys):
    assert teams.run_import([], base_config) == 1
    bad = tmp_path / "x.vtt"
    bad.write_text("WEBVTT\n", encoding="utf-8")
    assert teams.run_import([str(bad)], base_config) == 1
    assert teams.run_import([str(bad), "--at=yesterday"], base_config) == 1
    assert "--at must look like" in capsys.readouterr().out
