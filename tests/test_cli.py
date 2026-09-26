"""Tests for transcribe.cli: argument dispatch for every command path."""

import sys

import pytest

from transcribe import cli
from transcribe.cli import configure, main


@pytest.fixture
def stub_handlers(monkeypatch):
    """Replace every command handler with a recorder so dispatch is observable."""
    calls = {}
    monkeypatch.setattr(
        cli, "process_video_file", lambda *a, **k: calls.setdefault("process", (a, k))
    )
    monkeypatch.setattr(cli, "watch_directory", lambda *a, **k: calls.setdefault("watch", (a, k)))
    monkeypatch.setattr(cli, "setup_daemon", lambda *a, **k: calls.setdefault("daemon", (a, k)))
    monkeypatch.setattr(cli, "configure", lambda: calls.setdefault("configure", True))
    monkeypatch.setattr(cli, "load_config", lambda: {"watch_directory": "/cfg/watch"})
    return calls


def _run(monkeypatch, argv):
    monkeypatch.setattr(cli.sys, "argv", ["transcribe", *argv])


# --- no args / help / version ----------------------------------------------


def test_no_args_prints_usage_and_exits_1(monkeypatch, stub_handlers, capsys):
    _run(monkeypatch, [])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 1
    assert "Usage:" in capsys.readouterr().out


@pytest.mark.parametrize("flag", ["--help", "-h", "help"])
def test_help_exits_0(monkeypatch, stub_handlers, capsys, flag):
    _run(monkeypatch, [flag])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 0
    assert "Usage:" in capsys.readouterr().out


@pytest.mark.parametrize("flag", ["--version", "-v", "version"])
def test_version_exits_0(monkeypatch, stub_handlers, capsys, flag):
    _run(monkeypatch, [flag])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 0
    out = capsys.readouterr().out
    assert out.startswith("transcribe ")
    assert "(python package)" in out  # not frozen in tests


# --- config / setup-daemon --------------------------------------------------


def test_config_command(monkeypatch, stub_handlers):
    _run(monkeypatch, ["config"])
    main()
    assert stub_handlers.get("configure") is True


def test_setup_daemon_command(monkeypatch, stub_handlers):
    _run(monkeypatch, ["setup-daemon"])
    main()
    assert "daemon" in stub_handlers
    (args, _kwargs) = stub_handlers["daemon"]
    assert args[0] == {"watch_directory": "/cfg/watch"}


# --- watch ------------------------------------------------------------------


def test_watch_with_explicit_directory(monkeypatch, stub_handlers):
    _run(monkeypatch, ["watch", "/custom/dir"])
    main()
    (args, _kwargs) = stub_handlers["watch"]
    assert args[0] == "/custom/dir"
    assert args[1] == {"watch_directory": "/cfg/watch"}


def test_watch_defaults_to_config_directory(monkeypatch, stub_handlers):
    _run(monkeypatch, ["watch"])
    main()
    (args, _kwargs) = stub_handlers["watch"]
    assert args[0] == "/cfg/watch"


def test_watch_json_flag_does_not_become_directory(monkeypatch, stub_handlers):
    # `--json` is stripped globally, so watch falls back to the config dir
    # rather than treating "--json" as the watch directory.
    _run(monkeypatch, ["watch", "--json"])
    main()
    (args, _kwargs) = stub_handlers["watch"]
    assert args[0] == "/cfg/watch"


def test_watch_json_flag_with_explicit_directory(monkeypatch, stub_handlers):
    _run(monkeypatch, ["watch", "--json", "/custom/dir"])
    main()
    (args, _kwargs) = stub_handlers["watch"]
    assert args[0] == "/custom/dir"


# --- single file ------------------------------------------------------------


def test_single_file_dispatch(monkeypatch, stub_handlers, tmp_path):
    video = tmp_path / "v.mov"
    video.write_bytes(b"d")
    _run(monkeypatch, [str(video)])
    main()
    (args, kwargs) = stub_handlers["process"]
    assert args[0] == str(video)
    assert kwargs["write_json"] is False


def test_single_file_with_json_flag(monkeypatch, stub_handlers, tmp_path):
    video = tmp_path / "v.mov"
    video.write_bytes(b"d")
    _run(monkeypatch, [str(video), "--json"])
    main()
    (args, kwargs) = stub_handlers["process"]
    assert args[0] == str(video)
    assert kwargs["write_json"] is True


def test_json_flag_position_independent(monkeypatch, stub_handlers, tmp_path):
    video = tmp_path / "v.mov"
    video.write_bytes(b"d")
    _run(monkeypatch, ["--json", str(video)])
    main()
    (args, kwargs) = stub_handlers["process"]
    assert args[0] == str(video)
    assert kwargs["write_json"] is True


def test_missing_file_errors_and_exits_1(monkeypatch, stub_handlers, capsys):
    _run(monkeypatch, ["/does/not/exist.mov"])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 1
    assert "Error: File not found: /does/not/exist.mov" in capsys.readouterr().out
    assert "process" not in stub_handlers


def test_json_flag_only_no_positional_exits_1(monkeypatch, stub_handlers, capsys):
    _run(monkeypatch, ["--json"])
    with pytest.raises(SystemExit) as exc:
        main()
    # "--json" stripped, no positional remains -> usage + exit 1.
    assert exc.value.code == 1
    assert "Usage:" in capsys.readouterr().out


# --- configure() output -----------------------------------------------------


def test_configure_masks_secrets(monkeypatch, capsys):
    cfg = {
        "openai_api_key": "sk-secret",
        "anthropic_api_key": "",
        "slack_webhook_url": "https://hooks/x",
        "slack_bot_token": "xoxb-super-secret",
        "watch_directory": "/w",
    }
    monkeypatch.setattr(cli, "load_config", lambda: cfg)
    configure()
    out = capsys.readouterr().out
    # Secret with a value is masked, empty secret shows "(not set)".
    assert "openai_api_key: ***" in out
    assert "anthropic_api_key: (not set)" in out
    assert "slack_webhook_url: ***" in out
    # A populated bot token is masked too (key name contains "token").
    assert "slack_bot_token: ***" in out
    # Non-secret value shown verbatim.
    assert "watch_directory: /w" in out
    # Never leak the raw secret.
    assert "sk-secret" not in out
    assert "https://hooks/x" not in out
    assert "xoxb-super-secret" not in out


# --- categorise scope --------------------------------------------------------


def test_categorise_without_a_target_does_not_run_over_everything(monkeypatch, capsys):
    """One LLM call per meeting is not something a bare command should do."""
    from transcribe import cli

    monkeypatch.setattr(
        cli, "load_config", lambda: {"destination_directory": "/tmp", "anthropic_api_key": "sk"}
    )
    monkeypatch.setattr(sys, "argv", ["transcribe", "categorise"])
    with pytest.raises(SystemExit) as exit_info:
        cli.main()
    assert exit_info.value.code == 1
    assert "--all" in capsys.readouterr().out


def test_categorise_all_is_the_way_to_ask_for_everything(monkeypatch, tmp_path):
    from transcribe import cli

    (tmp_path / "a meeting").mkdir()
    captured = {}
    monkeypatch.setattr(
        cli,
        "load_config",
        lambda: {"destination_directory": str(tmp_path), "anthropic_api_key": "sk"},
    )
    import transcribe.categorise as categorise_mod

    monkeypatch.setattr(
        categorise_mod,
        "categorise_folders",
        lambda folders, config, overwrite=False: captured.update(folders=folders) or 0,
    )
    monkeypatch.setattr(sys, "argv", ["transcribe", "categorise", "--all"])
    with pytest.raises(SystemExit):
        cli.main()
    assert len(captured["folders"]) == 1
