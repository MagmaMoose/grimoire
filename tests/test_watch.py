"""Tests for transcribe.watch: the VideoHandler event filtering.

The watchdog Observer loop is an infinite blocking call, so these tests target
the handler's file-filtering logic directly rather than running the observer.
The handler class is defined inside ``watch_directory``; we drive it via a
mocked Observer that captures the scheduled handler, then feed it fake events.
"""

import sys
import types

import pytest

from transcribe import watch


class FakeEvent:
    def __init__(self, src_path, is_directory=False):
        self.src_path = src_path
        self.is_directory = is_directory


@pytest.fixture
def captured_handler(monkeypatch, base_config):
    """Run watch_directory with a fake Observer, returning the VideoHandler.

    The observer's ``start`` raises KeyboardInterrupt immediately so the
    ``while True`` loop never blocks, and we capture the handler instance that
    was scheduled.
    """
    captured = {}

    class FakeObserver:
        def schedule(self, handler, directory, recursive=False):
            captured["handler"] = handler
            captured["directory"] = directory

        def start(self):
            captured["started"] = True

        def stop(self):
            captured["stopped"] = True

        def join(self):
            captured["joined"] = True

    fake_watchdog = types.ModuleType("watchdog")
    fake_observers = types.ModuleType("watchdog.observers")
    fake_observers.Observer = FakeObserver
    fake_events = types.ModuleType("watchdog.events")
    fake_events.FileSystemEventHandler = object
    monkeypatch.setitem(sys.modules, "watchdog", fake_watchdog)
    monkeypatch.setitem(sys.modules, "watchdog.observers", fake_observers)
    monkeypatch.setitem(sys.modules, "watchdog.events", fake_events)

    # The `while True: time.sleep(1)` loop blocks forever; make the FIRST
    # time.sleep raise KeyboardInterrupt (inside the try/except in the source,
    # so it breaks the loop cleanly), then become a no-op so the handler's
    # later 2-second wait does not also raise.
    sleeps = {"n": 0}

    def fake_sleep(_seconds):
        sleeps["n"] += 1
        if sleeps["n"] == 1:
            raise KeyboardInterrupt

    monkeypatch.setattr(watch.time, "sleep", fake_sleep)

    processed = []
    monkeypatch.setattr(watch, "process_video_file", lambda path, cfg: processed.append(path))
    captured["processed"] = processed

    base_config["video_extensions"] = [".mov", ".mp4"]
    watch.watch_directory("/watch/here", base_config)
    return captured


def test_observer_scheduled_for_directory(captured_handler):
    assert captured_handler["directory"] == "/watch/here"
    assert captured_handler.get("stopped") is True
    assert captured_handler.get("joined") is True


def test_video_file_is_processed(monkeypatch, captured_handler, tmp_path):
    handler = captured_handler["handler"]
    video = tmp_path / "clip.mov"
    video.write_bytes(b"d")

    handler.on_created(FakeEvent(str(video)))
    assert captured_handler["processed"] == [str(video)]


def test_non_video_extension_ignored(captured_handler, tmp_path):
    handler = captured_handler["handler"]
    txt = tmp_path / "note.txt"
    txt.write_text("x")
    handler.on_created(FakeEvent(str(txt)))
    assert captured_handler["processed"] == []


def test_directory_event_ignored(captured_handler, tmp_path):
    handler = captured_handler["handler"]
    handler.on_created(FakeEvent(str(tmp_path), is_directory=True))
    assert captured_handler["processed"] == []


def test_missing_file_not_processed(captured_handler):
    handler = captured_handler["handler"]
    # A .mov path that does not exist on disk -> skipped after the wait.
    handler.on_created(FakeEvent("/nope/gone.mov"))
    assert captured_handler["processed"] == []


def test_watchdog_import_error_exits(monkeypatch, base_config):
    # Force the in-function import of watchdog.observers to fail.
    import builtins

    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name.startswith("watchdog"):
            raise ImportError("no watchdog")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    with pytest.raises(SystemExit) as exc:
        watch.watch_directory("/x", base_config)
    assert exc.value.code == 1


# --- Voice Memos polling ----------------------------------------------------------


class _Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def test_voice_memos_are_polled_every_few_minutes(monkeypatch):
    import threading

    import transcribe.voicememos as vm

    calls = []
    monkeypatch.setattr(vm, "import_new_memos", lambda config: calls.append(1) or (0, 0, 0))
    clock = _Clock()
    poller = watch.VoiceMemoPoller({}, threading.Lock(), clock=clock)
    poller.poll()
    poller.poll()
    assert len(calls) == 1
    clock.now += watch.VOICE_MEMOS_POLL_SECONDS
    poller.poll()
    assert len(calls) == 2


def test_voice_memos_polling_can_be_switched_off(monkeypatch):
    import threading

    import transcribe.voicememos as vm

    monkeypatch.setattr(vm, "import_new_memos", lambda config: pytest.fail("must not import"))
    poller = watch.VoiceMemoPoller({"voice_memos_auto_import": False}, threading.Lock())
    assert poller.poll() is None


def test_a_permission_failure_backs_off_for_an_hour(monkeypatch, capsys):
    import threading

    import transcribe.voicememos as vm

    def denied(config):
        raise vm.VoiceMemosPermissionDenied("needs Full Disk Access")

    monkeypatch.setattr(vm, "import_new_memos", denied)
    clock = _Clock()
    poller = watch.VoiceMemoPoller({}, threading.Lock(), clock=clock)
    poller.poll()
    assert poller.next_check == watch.VOICE_MEMOS_BLOCKED_SECONDS
    assert "paused for an hour" in capsys.readouterr().out


def test_no_voice_memos_library_stops_polling(monkeypatch):
    import threading

    import transcribe.voicememos as vm

    def missing(config):
        raise vm.VoiceMemosUnavailable("Voice Memos is not set up on this Mac")

    monkeypatch.setattr(vm, "import_new_memos", missing)
    poller = watch.VoiceMemoPoller({}, threading.Lock(), clock=_Clock())
    poller.poll()
    assert poller.next_check == float("inf")


def test_an_unexpected_failure_does_not_stop_the_watcher(monkeypatch, capsys):
    import threading

    import transcribe.voicememos as vm

    def explode(config):
        raise RuntimeError("sqlite said no")

    monkeypatch.setattr(vm, "import_new_memos", explode)
    poller = watch.VoiceMemoPoller({}, threading.Lock(), clock=_Clock())
    assert poller.poll() is None
    assert "Voice Memos import failed" in capsys.readouterr().out
