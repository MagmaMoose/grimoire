#!/usr/bin/env python3
"""Command-line entry point for transcribe.

Usage:
  transcribe <video_file>           - Transcribe a single file
  transcribe watch <directory>      - Watch directory for new files
  transcribe setup-daemon           - Install background daemon
  transcribe autorecord             - Record meetings automatically via OBS
  transcribe setup-autorecord       - Install the auto-record agent
  transcribe voicememos [--import]  - List/import macOS Voice Memos
  transcribe menubar                - Menu bar app with a manual override
  transcribe config                 - Configure settings
  transcribe doctor                 - Check dependencies and models
  transcribe calendar-check         - Verify macOS Calendar access
  transcribe --version              - Show version information
Requires: brew install whisper-cpp ffmpeg
"""

import shutil
import sys
from pathlib import Path

from . import __version__
from .config import CONFIG_FILE, load_config
from .daemon import setup_autorecord_daemon, setup_daemon
from .processing import process_video_file
from .tls import _ensure_tls_ca_bundle
from .watch import watch_directory

# Run TLS fixup as early as possible, before any network clients are created
_ensure_tls_ca_bundle()

# Force line-buffered output for daemon logging
try:
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
except Exception:
    pass


def configure():
    """Interactive configuration."""
    config = load_config()

    print("\nTranscribe Configuration\n" + "=" * 40)
    # Mask any key whose name suggests it holds a credential.
    secret_markers = ("api_key", "webhook", "token", "secret")
    print("\nCurrent configuration:")
    for key, value in config.items():
        if any(marker in key.lower() for marker in secret_markers):
            display_value = "***" if value else "(not set)"
        else:
            display_value = value
        print(f"  {key}: {display_value}")

    print("\nEdit the configuration file at:")
    print(f"  {CONFIG_FILE}")
    print("\nRequired for full functionality:")
    print("  - anthropic_api_key (or openai_api_key): notes and summaries")
    print("  - slack_webhook_url: notifications")


def doctor():
    """Report on every dependency the pipeline can use, and what is missing."""
    config = load_config()
    print("\nTranscribe doctor\n" + "=" * 40)

    ok = True

    print("\nCommand-line tools:")
    for tool, install in (
        ("ffmpeg", "brew install ffmpeg"),
        ("ffprobe", "brew install ffmpeg"),
        ("whisper-cli", "brew install whisper-cpp"),
    ):
        path = shutil.which(tool)
        if path:
            print(f"  ✓ {tool}: {path}")
        else:
            ok = False
            print(f"  ✗ {tool}: not found — {install}")

    print("\nTranscription:")
    print(f"  model: {config.get('whisper_model')}")
    print(f"  VAD: {'on' if config.get('whisper_vad', True) else 'OFF (not recommended)'}")

    print("\nSpeaker attribution (diarization):")
    if not config.get("diarization_enabled", True):
        print("  - disabled in config")
    else:
        missing = [name for name in ("sherpa_onnx", "numpy") if not _importable(name)]
        if missing:
            ok = False
            print(f"  ✗ missing: {', '.join(missing)}")
            print("    install with: pip install 'transcribe[diarize]'")
        else:
            print("  ✓ sherpa-onnx and numpy available")

    print("\nCalendar:")
    if not config.get("calendar_enabled", True):
        print("  - disabled in config")
    elif not _importable("EventKit"):
        print("  ✗ pyobjc-framework-EventKit not installed")
        print("    install with: pip install 'transcribe[calendar]'")
    else:
        _report_calendar_status()

    print("\nLLM provider:")
    provider = (config.get("llm_provider") or "claude").strip().lower()
    key = config.get("openai_api_key" if provider == "openai" else "anthropic_api_key")
    if key:
        model = config.get("openai_model" if provider == "openai" else "anthropic_model")
        print(f"  ✓ {provider} configured (model: {model})")
    else:
        print(f"  ✗ {provider} selected but no API key set in {CONFIG_FILE}")
        print("    Without it you still get transcripts, but no notes or summaries.")

    print("\nAuto-recording:")
    if not _importable("obsws_python"):
        print("  ✗ obsws-python not installed")
        print("    install with: pip install 'transcribe[autorecord]'")
    else:
        from .autorecord import obs_is_running

        print("  ✓ obsws-python available")
        print(f"  OBS running: {'yes' if obs_is_running() else 'no'}")
        if not config.get("obs_password"):
            print("  - obs_password not set (OBS > Tools > WebSocket Server Settings)")

    print("\nSlack:")
    if config.get("slack_bot_token") or config.get("slack_webhook_url"):
        print("  ✓ configured")
    else:
        print("  - not configured (optional)")

    print()
    return 0 if ok else 1


def _importable(module_name):
    """True when ``module_name`` can be imported."""
    import importlib.util

    try:
        return importlib.util.find_spec(module_name) is not None
    except (ImportError, ValueError):
        return False


def _report_calendar_status():
    """Print the current EventKit authorization status."""
    from .calendars import CalendarUnavailable, authorization_status

    try:
        status, label = authorization_status()
    except CalendarUnavailable as e:
        print(f"  ✗ {e}")
        return
    if status in (3, 5):
        print(f"  ✓ access granted ({label})")
    elif status == 0:
        print("  - not yet requested — run: transcribe calendar-check")
    else:
        print(f"  ✗ access {label} — enable under System Settings > Privacy & Security > Calendars")


def calendar_check():
    """Trigger the macOS Calendar permission prompt and list upcoming events.

    Run this from a normal terminal session. A launchd daemon has no UI to show
    the permission prompt, so access has to be granted interactively once.
    """
    from datetime import datetime, timedelta

    from .calendars import CalendarUnavailable, fetch_macos_events

    config = load_config()
    now = datetime.now()
    try:
        events = fetch_macos_events(now - timedelta(days=1), now + timedelta(days=7), config)
    except CalendarUnavailable as e:
        print(f"✗ {e}")
        return 1
    except Exception as e:
        print(f"✗ Calendar lookup failed ({type(e).__name__}: {e})")
        return 1

    print(f"✓ Calendar access working — {len(events)} event(s) in the next 7 days")
    for event in events[:15]:
        attendees = f" — {len(event['attendees'])} attendee(s)" if event["attendees"] else ""
        print(f"  {event['start'][:16].replace('T', ' ')}  {event['title']}{attendees}")
    if not events:
        print("  (no events found — check that Calendar.app has your accounts synced)")
    return 0


def _report_devices():
    """Print every audio input and whether it is currently in use.

    This is the signal auto-recording keys off, so being able to see it is the
    fastest way to tell why a meeting was or was not picked up.
    """
    from .audio import (
        DEFAULT_IGNORED_DEVICES,
        AudioUnavailable,
        active_input_devices,
        device_name,
        input_devices,
        is_ignored,
    )

    try:
        devices = input_devices()
    except AudioUnavailable as e:
        print(f"✗ {e}")
        return 1

    active = set(active_input_devices())
    print("\nAudio inputs:")
    for device_id in devices:
        name = device_name(device_id)
        if is_ignored(name, DEFAULT_IGNORED_DEVICES):
            note = "ignored (virtual device)"
        elif name in active:
            note = "IN USE"
        else:
            note = "idle"
        print(f"  {note:<26} {name}")
    from .autorecord import Presence, meeting_in_progress
    from .camera import DEFAULT_IGNORED_CAMERAS as CAM_IGNORED
    from .camera import active_cameras, camera_name, cameras
    from .camera import is_ignored as camera_is_ignored

    active_cams = set(active_cameras())
    print("\nCameras:")
    for device_id in cameras():
        name = camera_name(device_id)
        if camera_is_ignored(name, CAM_IGNORED):
            note = "ignored (virtual device)"
        elif name in active_cams:
            note = "IN USE"
        else:
            note = "idle"
        print(f"  {note:<26} {name}")

    config = load_config()
    presence = Presence(mic=bool(active), camera=bool(active_cams))
    verdict = meeting_in_progress(presence, config)
    print(f"\nSignals: {presence.describe()}")
    print(f"Would record: {'yes' if verdict else 'no'}")
    if presence.mic and not verdict:
        print("  (microphone alone is not enough; needs the camera on or a calendar meeting)")
    print()
    return 0


def _voice_memos(args, selected):
    """List or import recordings from the macOS Voice Memos app."""
    from datetime import datetime, timedelta

    from .voicememos import (
        VoiceMemosUnavailable,
        describe_library,
        inspect_storage,
        list_memos,
    )

    config = load_config()

    if "--debug" in args:
        try:
            found = describe_library()
        except VoiceMemosUnavailable as e:
            print(f"✗ {e}")
            return 1
        print(f"\ndatabase: {found['database']}")
        print(f"recording table: {found['recording_table']} ({found['recording_count']} rows)")
        print("resolved columns:")
        for key, value in found["resolved"].items():
            print(f"  {key:<11} {value or '(not found)'}")
        transcript_columns = found["transcript_columns_anywhere"] or "none"
        print(f"\ntranscript-ish columns anywhere: {transcript_columns}")
        print(f"\nall columns: {', '.join(found['columns'])}")
        print(f"\ntables: {', '.join(found['tables'])}")

        storage = inspect_storage()
        print(f"\nrecordings directory: {storage['directory']}")
        if storage.get("error"):
            print(f"  error: {storage['error']}")
        else:
            print(f"  file types: {storage['extensions']}")
            print("  most recent entries:")
            for entry in storage["recent"][:25]:
                size = f"{entry['size']:,}" if entry["size"] >= 0 else "?"
                print(f"    {entry['kind']:<4} {size:>12}  {entry['name']}")
        print()
        return 0

    since = None
    for arg in args:
        if arg.startswith("--since-days="):
            since = datetime.now() - timedelta(days=float(arg.split("=", 1)[1]))
    if since is None and "--all" not in args:
        since = datetime.now() - timedelta(days=1)

    try:
        memos = list_memos(since=since)
    except VoiceMemosUnavailable as e:
        print(f"✗ {e}")
        return 1

    if not memos:
        print("No Voice Memos found in that window. Try --all, or --debug to see the schema.")
        return 0

    if "--import" not in args:
        print(f"\n{len(memos)} memo(s):\n")
        for index, memo in enumerate(memos, 1):
            when = memo["recorded_at"].strftime("%Y-%m-%d %H:%M") if memo["recorded_at"] else "?"
            mins = f"{float(memo['duration']) / 60:.0f} min" if memo["duration"] else "?"
            words = len(memo["transcript"].split()) if memo["transcript"] else 0
            state = f"{words:,} words" if words else "NO TRANSCRIPT"
            print(f"  {index}. {when}  {mins:>7}  {state:>14}  {memo['title']}")
        print("\nAdd --import to run these through the notes pipeline.\n")
        return 0

    from .processing import process_transcript, process_video_file

    # Transcribing locally beats reusing the app's transcript. Measured on a
    # 53-minute meeting: 7,713 words against roughly 5,000, and every technical
    # term the app garbled came out right -- "trunk based" for "Trump-based",
    # "cherry pick from master" for "charity pick from after", Kubernetes for
    # "humanitis". The local path also produces timestamps and speaker
    # attribution, neither of which the app's transcript carries.
    prefer_app = "--use-app-transcript" in args

    for memo in memos:
        if prefer_app and memo["transcript"]:
            process_transcript(
                memo["audio_path"],
                memo["transcript"],
                config,
                title=memo["title"],
                recorded_at=memo["recorded_at"],
                duration=memo["duration"],
            )
        elif memo["audio_path"]:
            process_video_file(memo["audio_path"], config)
        elif memo["transcript"]:
            # No readable audio, so the app's transcript beats nothing.
            print(f"{memo['title']!r}: audio unreadable, using the Voice Memos transcript")
            process_transcript(
                None,
                memo["transcript"],
                config,
                title=memo["title"],
                recorded_at=memo["recorded_at"],
                duration=memo["duration"],
            )
        else:
            print(f"Skipping {memo['title']!r}: no readable audio and no transcript")
    return 0


def _print_usage():
    print("Usage:")
    print("  transcribe <video_file> [--json] [--flat] [--no-split] [--keep-source]")
    print("                                    - Transcribe a single file")
    print("  transcribe watch [directory]      - Watch directory for new files")
    print("  transcribe setup-daemon           - Install background daemon")
    print("  transcribe autorecord             - Record meetings automatically via OBS")
    print("  transcribe setup-autorecord       - Install the auto-record agent")
    print("  transcribe notes <folders>        - Write notes from an existing transcript")
    print("  transcribe categorise <folders>   - Label meetings with categories")
    print("       --all          every meeting that has none yet")
    print("       --overwrite    replace categories that are already set")
    print("  transcribe record start|stop      - Drive an OBS recording")
    print("  transcribe voicememos [--import]  - List/import macOS Voice Memos")
    print("       --debug        show the library schema")
    print("       --all          every memo, not just the last day")
    print("       --use-app-transcript  reuse the app's transcript instead of")
    print("                             transcribing locally (faster, worse)")
    print("  transcribe menubar                - Menu bar app with a manual override")
    print("  transcribe mic                    - Show inputs and whether a meeting is detected")
    print("  transcribe config                 - Show/edit configuration")
    print("  transcribe doctor                 - Check dependencies and models")
    print("  transcribe calendar-check         - Verify macOS Calendar access")
    print("  transcribe --version              - Show version information")


def _print_version():
    # Prefer package metadata when available
    try:
        from importlib.metadata import version as _version

        ver = _version("transcribe")
    except Exception:
        ver = __version__
    source = "brew/pyinstaller" if getattr(sys, "frozen", False) else "python package"
    print(f"transcribe {ver} ({source})")


def main():
    """Main entry point for the transcribe command."""
    # Strip global flags before command dispatch so that e.g. `transcribe watch
    # --json` does not mistake a flag for the watch directory.
    argv = sys.argv[1:]
    flags = {
        "--json": "write_json",
        "--flat": "flat",
        "--no-split": "no_split",
        "--no-diarize": "no_diarize",
        "--keep-source": "keep_source",
    }
    selected = {name for arg, name in flags.items() if arg in argv}
    args = [arg for arg in argv if arg not in flags]

    if not args:
        _print_usage()
        sys.exit(1)

    command = args[0]

    if command in ["--help", "-h", "help"]:
        _print_usage()
        sys.exit(0)
    elif command in ["--version", "-v", "version"]:
        _print_version()
        sys.exit(0)
    elif command == "config":
        configure()
    elif command == "doctor":
        sys.exit(doctor())
    elif command == "calendar-check":
        sys.exit(calendar_check())
    elif command == "setup-daemon":
        config = load_config()
        setup_daemon(config)
    elif command == "setup-autorecord":
        setup_autorecord_daemon(load_config())
    elif command == "autorecord":
        from .autorecord import watch as autorecord_watch

        autorecord_watch(load_config())
    elif command == "mic":
        sys.exit(_report_devices())
    elif command == "voicememos":
        sys.exit(_voice_memos(args[1:], selected))
    elif command == "menubar":
        from .menubar import MenuBarUnavailable
        from .menubar import run as run_menubar

        try:
            run_menubar(load_config())
        except MenuBarUnavailable as e:
            print(f"✗ {e}")
            sys.exit(1)
    elif command == "notes":
        from .from_transcript import generate_for_folders

        config = _apply_flags(load_config(), selected)
        folders = [a for a in args[1:] if not a.startswith("--")]
        if not folders:
            print("Usage: transcribe notes <meeting folder> [more folders]")
            sys.exit(1)
        sys.exit(generate_for_folders(folders, config))
    elif command == "categorise" or command == "categorize":
        from .categorise import categorise_folders

        config = load_config()
        folders = [a for a in args[1:] if not a.startswith("--")]
        if not folders and "--all" not in args:
            # Running over the whole library is one LLM call per meeting, so it
            # has to be asked for. Bare "categorise", and anything whose only
            # arguments are flags, used to do exactly that.
            print("Usage: transcribe categorise <meeting folder> [more folders]")
            print("       transcribe categorise --all      every meeting without categories")
            print("       --overwrite                      replace categories already set")
            sys.exit(1)
        if not folders:
            destination = Path(config["destination_directory"])
            folders = sorted(str(p) for p in destination.glob("*") if p.is_dir())
            print(f"Categorising up to {len(folders)} meeting(s) in {destination}")
        sys.exit(categorise_folders(folders, config, overwrite="--overwrite" in args))
    elif command == "record":
        from .autorecord import (
            ObsUnavailable,
            connect,
            is_recording,
            launch_obs,
            start_recording,
            stop_recording,
        )

        action = args[1] if len(args) > 1 else "status"
        if action not in {"start", "stop", "status"}:
            print(f"Unknown action {action!r}. Use: transcribe record start|stop|status")
            sys.exit(1)

        config = load_config()
        try:
            if action == "start":
                launch_obs()
            client = connect(config)
            if action == "start":
                print("✓ Recording" if start_recording(client) else "Already recording")
            elif action == "stop":
                # stop_recording returns the output path, which OBS does not
                # always report, so it cannot stand in for "did it stop".
                was_recording = is_recording(client)
                stop_recording(client)
                print("✓ Stopped" if was_recording else "Not recording")
            else:
                print("recording" if is_recording(client) else "idle")
        except ObsUnavailable as e:
            print(f"✗ {e}")
            sys.exit(1)
    elif command == "watch":
        config = _apply_flags(load_config(), selected)
        directory = args[1] if len(args) > 1 else config["watch_directory"]
        watch_directory(directory, config)
    else:
        # Single-file mode.
        video_file = args[0]
        if not Path(video_file).exists():
            print(f"Error: File not found: {video_file}")
            sys.exit(1)

        config = _apply_flags(load_config(), selected)
        process_video_file(video_file, config, write_json="write_json" in selected)


def _apply_flags(config, selected):
    """Let command-line flags override the corresponding config keys."""
    if "flat" in selected:
        config["meeting_mode"] = False
    if "no_split" in selected:
        config["split_meetings"] = False
        config["split_video"] = False
    if "no_diarize" in selected:
        config["diarization_enabled"] = False
    if "keep_source" in selected:
        # Leave the recording where it is. Reprocessing a meeting's own media
        # would otherwise move it out of the folder being reprocessed and into
        # whichever new folder the run produced.
        config["move_source_video"] = False
    return config


if __name__ == "__main__":
    main()
