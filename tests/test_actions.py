"""Tests for action items across meetings and their shared done state."""

import json

import pytest

from transcribe import actions
from transcribe.actions import (
    action_key,
    collect,
    is_mine,
    load_done,
    named_owner,
    save_done,
    set_done,
)


def make_meeting(root, name, steps, title="Camera subnets", started="2026-09-20T10:00:00"):
    folder = root / name
    folder.mkdir(parents=True)
    (folder / "notes.json").write_text(
        json.dumps(
            {
                "title": title,
                "start": 0,
                "recording_started_at": started,
                "notes": {"title": title, "next_steps": steps},
            }
        )
    )
    return folder


def step(owner, title, detail=""):
    return {"owner": owner, "title": title, "detail": detail}


@pytest.mark.parametrize(
    "owner",
    ["Unassigned", "Speaker 1", "SPEAKER_00", "speaker 12", "Speaker A", "Unknown speaker", ""],
)
def test_anonymous_owners_are_nobody(owner):
    """ "Speaker 2" says which voice, not whose job it is."""
    assert named_owner(owner) is None


@pytest.mark.parametrize("owner", ["Priya", "Sam Okoro", "Speakerman", "The platform team"])
def test_real_owners_are_kept(owner):
    assert named_owner(owner) == owner


@pytest.mark.parametrize(
    ("owner", "expected"),
    [
        ("Caleb", True),
        ("Caleb Sargeant", True),
        ("caleb", True),
        ("Caleb and Priya", True),
        ("Priya", False),
        ("Speaker 1", False),
    ],
)
def test_mine_matches_the_first_name_or_the_full_name(owner, expected):
    assert is_mine(owner, "Caleb Sargeant") is expected


def test_nothing_is_mine_without_a_name():
    assert not is_mine("Caleb", "")


def test_keys_match_the_app_with_or_without_a_trailing_slash():
    """The app keyed a directory URL, which can end in a slash."""
    assert action_key("/m/2026 Standup/", "Sam", "Ship", "it") == action_key(
        "/m/2026 Standup", "Sam", "Ship", "it"
    )


def test_done_state_written_by_the_app_is_read(private_config_dir):
    private_config_dir.mkdir(parents=True, exist_ok=True)
    (private_config_dir / "action-items-done.json").write_text(
        json.dumps(["/m/2026 Standup/|SamShipit"])
    )
    assert "/m/2026 Standup|SamShipit" in load_done()


def test_done_state_round_trips():
    save_done({"/m/a|xyz"})
    assert load_done() == {"/m/a|xyz"}


def test_collect_finds_every_meeting_newest_first(tmp_path):
    make_meeting(tmp_path, "older", [step("Sam", "Old")], started="2026-01-01T09:00:00")
    make_meeting(tmp_path, "newer", [step("Priya", "New")], started="2026-09-01T09:00:00")
    (tmp_path / "not a meeting").mkdir()
    items = collect(tmp_path)
    assert [item.title for item in items] == ["New", "Old"]


def test_collect_can_be_limited_to_recent_meetings(tmp_path):
    make_meeting(tmp_path, "older", [step("Sam", "Old")], started="2020-01-01T09:00:00")
    make_meeting(tmp_path, "newer", [step("Priya", "New")], started="2099-01-01T09:00:00")
    assert [item.title for item in collect(tmp_path, since_days=30)] == ["New"]


def test_refs_tick_items_off_and_back_on(tmp_path):
    make_meeting(tmp_path, "m", [step("Sam", "Ship it")])
    [item] = collect(tmp_path)
    assert set_done([item], [item.ref]) == [item]
    assert item.key in load_done()
    set_done([item], [item.ref.upper()], done=False)
    assert item.key not in load_done()


def test_run_lists_outstanding_items(tmp_path, capsys):
    make_meeting(tmp_path, "m", [step("Sam", "Ship it"), step("Speaker 2", "Book a room")])
    assert actions.run([], {"destination_directory": str(tmp_path)}) == 0
    output = capsys.readouterr().out
    assert "2 outstanding of 2" in output
    assert "Ship it  (Sam)" in output
    assert "(Speaker 2)" not in output


def test_run_marks_done_by_ref(tmp_path, capsys):
    make_meeting(tmp_path, "m", [step("Sam", "Ship it")])
    [item] = collect(tmp_path)
    config = {"destination_directory": str(tmp_path)}
    assert actions.run(["done", item.ref], config) == 0
    assert "✓ Done: Ship it" in capsys.readouterr().out
    assert actions.run([], config) == 0
    assert "0 outstanding of 1" in capsys.readouterr().out


def test_run_reports_an_unknown_ref(tmp_path, capsys):
    make_meeting(tmp_path, "m", [step("Sam", "Ship it")])
    assert actions.run(["done", "nope"], {"destination_directory": str(tmp_path)}) == 1
    assert "No action item with ref nope" in capsys.readouterr().out


def test_mine_keeps_mine_and_unassigned(tmp_path, capsys):
    make_meeting(
        tmp_path,
        "m",
        [step("Caleb", "Mine"), step("Priya", "Hers"), step("Unassigned", "Anyone's")],
    )
    config = {"destination_directory": str(tmp_path), "user_name": "Caleb"}
    assert actions.run(["--mine", "--json"], config) == 0
    titles = [entry["title"] for entry in json.loads(capsys.readouterr().out)]
    assert titles == ["Mine", "Anyone's"]


def test_mine_needs_a_name(tmp_path, capsys):
    assert actions.run(["--mine"], {"destination_directory": str(tmp_path)}) == 1
    assert "user_name" in capsys.readouterr().out


def test_done_items_are_hidden_unless_asked_for(tmp_path, capsys):
    make_meeting(tmp_path, "m", [step("Sam", "Ship it"), step("Sam", "Test it")])
    items = collect(tmp_path)
    set_done(items, [items[0].ref])
    config = {"destination_directory": str(tmp_path)}
    actions.run(["--json"], config)
    assert len(json.loads(capsys.readouterr().out)) == 1
    actions.run(["--json", "--all"], config)
    assert len(json.loads(capsys.readouterr().out)) == 2
    actions.run(["--json", "--done"], config)
    assert [entry["done"] for entry in json.loads(capsys.readouterr().out)] == [True]


def test_a_missing_destination_is_an_error(capsys):
    assert actions.run([], {}) == 1
