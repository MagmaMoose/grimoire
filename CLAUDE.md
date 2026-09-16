# Transcribe — agent context

Local, open-source meeting notes for macOS. Drop a recording in a folder and get back the
transcript, structured notes, and per-meeting folders — without the recording ever leaving
your machine.

## Quick orientation

- **Language:** Python 3.11+, macOS only.
- **Package:** `transcribe` v1.1.0, built with Hatchling, installed via `pip` or Homebrew.
- **Entry point:** `transcribe.cli:main` → `transcribe` command.
- **Source tree:** `src/transcribe/` (all modules listed below).
- **Tests:** `tests/` — one file per source module, run with pytest.
- **Tooling:** `uv` for environment and sync; `ruff` for lint and format.

## Build and test

```bash
uv sync                      # install deps (dev group included)
uv run ruff check .          # lint
uv run ruff format --check . # format check
uv run pytest -q             # all tests
uv run pytest tests/test_notes.py -q   # one module
```

CI runs on `macos-latest` and `ubuntu-latest` (the macOS-specific bits are behind
platform guards so the suite is cross-platform).

## Code conventions

- Line length 100, ruff rules `E F I UP B SIM RUF`.
- No comments that describe *what* — only *why* (non-obvious invariants, workarounds).
- No mid-pipeline `None` values; every optional stage degrades gracefully and prints a
  warning rather than raising.
- Functions that reach the LLM go through `llm.complete_json()` — never call the SDK
  directly from a business-logic module.
- macOS-only imports (`pyobjc`, `sherpa-onnx`, `obsws-python`, `rumps`) are guarded with
  `try/except ImportError` so the rest of the package works on Linux.

## Pipeline (high level)

1. `whisper.py` — ffmpeg extracts 16 kHz mono WAV → `whisper-cli` with Silero VAD →
   `[Segment]` (timestamped, text, no speaker yet).
2. `calendars.py` — EventKit pulls overlapping calendar events → titles + attendees.
3. `segmentation.py` — three-signal boundary detection (calendar / silence / LLM) →
   `[Meeting]`.
4. `diarize.py` — sherpa-onnx clusters voices per meeting → `segment.speaker`.
5. `notes.py` — LLM names speakers, then generates structured notes (forced tool call /
   JSON mode).
6. `render.py` — writes `notes.md`, `notes.html`, `notes.json`, `transcript.txt`,
   `summary.txt`.
7. `processing.py` — orchestrates the pipeline and files everything under
   `destination/<date> <title>/`.
8. `slack.py` — optional Slack webhook notification.

## Module map

| Module | Role |
| --- | --- |
| `cli.py` | Argument parsing, dispatch, `doctor`, `calendar-check`, `mic` |
| `config.py` | `~/.transcribe/config.yaml` load/save + `DEFAULT_CONFIG` |
| `audio.py` | CoreAudio: which inputs are in use (autorecord detection) |
| `camera.py` | CoreMediaIO: which cameras are in use |
| `autorecord.py` | Meeting-detection state machine, drives OBS via WebSocket |
| `menubar.py` | `rumps` menu bar app: manual override and signal visibility |
| `media.py` | ffmpeg/ffprobe: probe, extract audio, lossless video cut |
| `vocabulary.py` | Assembles the Whisper prompt from calendar + mined glossary |
| `segments.py` | `Segment` and `Meeting` dataclasses |
| `whisper.py` | Transcription with VAD, model download |
| `diarize.py` | sherpa-onnx speaker clustering and attribution |
| `calendars.py` | EventKit lookup; source registry for future calendar backends |
| `segmentation.py` | Meeting boundary detection |
| `notes.py` | Notes generation and speaker naming (LLM) |
| `llm.py` | Provider dispatch: Anthropic forced-tool-call + OpenAI JSON mode |
| `render.py` | Markdown / HTML / transcript renderers |
| `processing.py` | Pipeline orchestration and filing |
| `watch.py` | Watchdog directory watcher and file-stability wait |
| `daemon.py` | launchd plist generation |
| `links.py` | Resolves a linkable URL for a destination folder |
| `slack.py` | Slack webhook / bot-token notifications |
| `gdrive.py` | Optional Google Drive folder URL resolution |
| `tls.py` | TLS CA bundle fixup for frozen binaries |

## Optional extras

| Extra | Installs | Enables |
| --- | --- | --- |
| `diarize` | `sherpa-onnx`, `numpy` | Speaker attribution |
| `calendar` | `pyobjc-framework-EventKit` | Calendar titles / attendees |
| `gdrive` | `google-auth`, `google-api-python-client` | Drive folder links |
| `autorecord` | `obsws-python` | OBS-based auto-recording agent |
| `menubar` | `obsws-python`, `rumps` | Menu bar app |

## Configuration

Lives in `~/.transcribe/config.yaml`. Key settings: `watch_directory`, `destination_directory`,
`llm_provider` (`claude` or `openai`), `anthropic_api_key`, `anthropic_model`
(`claude-haiku-4-5-20251001` default), `whisper_model` (`large-v3-turbo` default),
`whisper_vad` (`true`), `diarization_enabled`, `calendar_enabled`, `split_meetings`.

## Workflows (CI)

- `ci.yml` — lint + format + pytest on `macos-latest` and `ubuntu-latest`.
- `quality.yml` — Brimyr patch-coverage gate on PRs (`magmamoose/brimyr@v1.9.7`).
- `chargate.yml` — MegaLinter + secret scanning on PRs (`magmamoose/chargate@v2.0.2`).
- `security.yml` — security scan.
- `release.yml` — release automation.
- `semantic-versioning.yml` — conventional-commit versioning.

## Security notes

- API keys and secrets in `~/.transcribe/config.yaml` (created `0600`, dir `0700`).
- Audio/video never leave the machine; only the text transcript is sent to the LLM.
- Model names validated against allowlist before use in paths or URLs.
- Downloaded archives validated (no path traversal, no symlinks).
- Filenames absolutised before passing to `ffmpeg`/`whisper-cli`.
