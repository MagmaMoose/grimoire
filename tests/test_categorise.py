"""Tests for assigning categories to meetings."""

import json

import pytest

from transcribe import categorise
from transcribe.categorise import (
    categorise_folders,
    categorise_meeting,
    existing_vocabulary,
    read_tags,
    write_tags,
)


@pytest.fixture
def config():
    return {"llm_provider": "claude", "anthropic_api_key": "sk-ant"}


def make_meeting(root, name, title="Branching strategy", summary="We discussed branching."):
    folder = root / name
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "notes.json").write_text(
        json.dumps(
            {
                "title": title,
                "attendees": ["Arno", "Caleb"],
                "calendar_event": {"title": title, "attendees": ["Arno"]},
                "notes": {
                    "title": title,
                    "summary": summary,
                    "sections": [{"heading": "Release cadence", "body": "x"}],
                },
            }
        )
    )
    return folder


# --- reading and writing tags ------------------------------------------------


def test_tags_round_trip(tmp_path):
    write_tags(tmp_path, ["Architecture", "Standup"])
    assert read_tags(tmp_path) == ["Architecture", "Standup"]


def test_writing_no_tags_removes_the_file(tmp_path):
    """An empty file is clutter in a folder the user browses in Finder."""
    write_tags(tmp_path, ["Architecture"])
    write_tags(tmp_path, [])
    assert not (tmp_path / "tags.json").exists()
    assert read_tags(tmp_path) == []


def test_reading_a_folder_with_no_tags(tmp_path):
    assert read_tags(tmp_path) == []


def test_reading_survives_corruption(tmp_path):
    (tmp_path / "tags.json").write_text("{not json")
    assert read_tags(tmp_path) == []


@pytest.mark.parametrize(
    ("given", "expected"),
    [
        (["Client", "client"], ["Client"]),
        (["  Spaced  ", "Spaced"], ["Spaced"]),
        (["a", "", "   ", "b"], ["a", "b"]),
    ],
)
def test_duplicates_and_blanks_are_dropped(tmp_path, given, expected):
    assert write_tags(tmp_path, given) == expected


# --- the shared vocabulary ---------------------------------------------------


def test_vocabulary_is_ordered_by_how_often_a_category_is_used(tmp_path):
    """The commonest categories go first so the model reaches for them."""
    for index in range(3):
        folder = tmp_path / f"meeting-{index}"
        folder.mkdir()
        write_tags(folder, ["Standup"])
    write_tags(tmp_path / "meeting-0", ["Standup", "Architecture"])
    assert existing_vocabulary(tmp_path)[0] == "Standup"
    assert "Architecture" in existing_vocabulary(tmp_path)


def test_vocabulary_of_a_missing_directory():
    assert existing_vocabulary("/nonexistent/meetings") == []


# --- categorising ------------------------------------------------------------


def test_categorise_writes_tags(monkeypatch, tmp_path, config):
    folder = make_meeting(tmp_path, "2026-08-27 1105 Branching")
    monkeypatch.setattr(
        categorise, "complete_json", lambda *a, **k: {"categories": ["Architecture", "Planning"]}
    )
    assert categorise_meeting(folder, config) == ["Architecture", "Planning"]
    assert read_tags(folder) == ["Architecture", "Planning"]


def test_categorise_sends_the_existing_vocabulary(monkeypatch, tmp_path, config):
    """Without it the model invents a near-synonym every time."""
    captured = {}
    folder = make_meeting(tmp_path, "m1")
    monkeypatch.setattr(
        categorise,
        "complete_json",
        lambda cfg, system, user, schema, **kw: captured.update(user=user) or {"categories": ["X"]},
    )
    categorise_meeting(folder, config, vocabulary=["Standup", "Architecture"])
    assert "Standup" in captured["user"]
    assert "Architecture" in captured["user"]


def test_categorise_sends_the_meeting_but_not_the_transcript(monkeypatch, tmp_path, config):
    """The notes already say what the meeting was; the transcript is wasted budget."""
    captured = {}
    folder = make_meeting(tmp_path, "m1", summary="We discussed the release cadence.")
    monkeypatch.setattr(
        categorise,
        "complete_json",
        lambda cfg, system, user, schema, **kw: captured.update(user=user) or {"categories": ["X"]},
    )
    categorise_meeting(folder, config)
    assert "release cadence" in captured["user"]
    assert "Arno" in captured["user"]


def test_already_categorised_meetings_are_left_alone(monkeypatch, tmp_path, config):
    folder = make_meeting(tmp_path, "m1")
    write_tags(folder, ["Chosen By Hand"])
    monkeypatch.setattr(
        categorise, "complete_json", lambda *a, **k: pytest.fail("should not be asked")
    )
    assert categorise_meeting(folder, config) is None
    assert read_tags(folder) == ["Chosen By Hand"]


def test_overwrite_replaces_existing_categories(monkeypatch, tmp_path, config):
    folder = make_meeting(tmp_path, "m1")
    write_tags(folder, ["Old"])
    monkeypatch.setattr(categorise, "complete_json", lambda *a, **k: {"categories": ["New"]})
    assert categorise_meeting(folder, config, overwrite=True) == ["New"]


def test_too_many_categories_are_capped(monkeypatch, tmp_path, config):
    """A model given no ceiling labels everything and the categories stop grouping."""
    folder = make_meeting(tmp_path, "m1")
    monkeypatch.setattr(
        categorise, "complete_json", lambda *a, **k: {"categories": ["A", "B", "C", "D", "E"]}
    )
    assert len(categorise_meeting(folder, config)) == categorise.MAX_TAGS_PER_MEETING


def test_a_folder_without_notes_is_skipped(monkeypatch, tmp_path, config):
    folder = tmp_path / "empty"
    folder.mkdir()
    monkeypatch.setattr(
        categorise, "complete_json", lambda *a, **k: pytest.fail("should not be asked")
    )
    assert categorise_meeting(folder, config) is None


def test_no_llm_configured_returns_nothing(tmp_path):
    folder = make_meeting(tmp_path, "m1")
    assert categorise_meeting(folder, {"anthropic_api_key": ""}) is None


def test_llm_failure_writes_nothing(monkeypatch, tmp_path, config):
    folder = make_meeting(tmp_path, "m1")
    monkeypatch.setattr(categorise, "complete_json", lambda *a, **k: None)
    assert categorise_meeting(folder, config) is None
    assert read_tags(folder) == []


# --- running over several folders --------------------------------------------


def test_categories_from_one_meeting_are_offered_to_the_next(monkeypatch, tmp_path, config):
    """Otherwise a single run coins a new synonym for every meeting in it."""
    seen = []
    first = make_meeting(tmp_path, "m1")
    second = make_meeting(tmp_path, "m2")

    def fake(cfg, system, user, schema, **kw):
        seen.append(user)
        return {"categories": ["Architecture"]}

    monkeypatch.setattr(categorise, "complete_json", fake)
    categorise_folders(
        [str(first), str(second)], {**config, "destination_directory": str(tmp_path)}
    )
    # The second request knows what the first one chose.
    assert "Architecture" in seen[1]


def test_no_folders_is_an_error(config):
    assert categorise_folders([], config) == 1


def test_no_provider_is_an_error(tmp_path):
    folder = make_meeting(tmp_path, "m1")
    assert categorise_folders([str(folder)], {"anthropic_api_key": ""}) == 1


def test_a_run_where_everything_fails_reports_failure(monkeypatch, tmp_path, config):
    folder = make_meeting(tmp_path, "m1")
    monkeypatch.setattr(categorise, "complete_json", lambda *a, **k: None)
    assert (
        categorise_folders([str(folder)], {**config, "destination_directory": str(tmp_path)}) == 1
    )


def test_a_run_where_some_succeed_reports_success(monkeypatch, tmp_path, config):
    good = make_meeting(tmp_path, "m1")
    monkeypatch.setattr(categorise, "complete_json", lambda *a, **k: {"categories": ["A"]})
    result = categorise_folders(
        [str(good), "/nonexistent/folder"], {**config, "destination_directory": str(tmp_path)}
    )
    assert result == 0


def test_a_bare_string_is_not_split_into_letters(tmp_path):
    """A model answering "Architecture" instead of ["Architecture"] produced one
    category per letter. The schema is a request, not a guarantee."""
    assert write_tags(tmp_path, "Architecture") == ["Architecture"]


def test_a_non_utf8_tags_file_reads_as_empty(tmp_path):
    (tmp_path / "tags.json").write_bytes(b"\xff\xfe not utf-8")
    assert read_tags(tmp_path) == []


def test_notes_json_that_is_not_an_object_is_skipped(tmp_path, config):
    folder = tmp_path / "m1"
    folder.mkdir()
    (folder / "notes.json").write_text("[1, 2, 3]")
    assert categorise_meeting(folder, config) is None


def test_one_bad_folder_does_not_abort_the_run(monkeypatch, tmp_path, config, capsys):
    good = make_meeting(tmp_path, "good")
    bad = make_meeting(tmp_path, "bad")

    def fake(cfg, system, user, schema, **kw):
        if "bad" in user:
            raise RuntimeError("provider exploded")
        return {"categories": ["Architecture"]}

    monkeypatch.setattr(categorise, "complete_json", fake)
    result = categorise_folders(
        [str(bad), str(good)], {**config, "destination_directory": str(tmp_path)}
    )
    assert result == 0
    assert read_tags(good) == ["Architecture"]
