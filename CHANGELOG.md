# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`transcribe import`** turns a Microsoft Teams transcript (`.vtt`, `.docx`, or text
  pasted from the transcript pane) into a meeting with notes. Teams' own speaker names
  and timings are kept, so whisper, diarisation and speaker naming are skipped. For tenants
  that switch off Graph access to transcripts, this is the way in.
- **`transcribe digest`** lists the notes of every meeting in a date range, filtered by
  grouping field, category or attendee. `--rollup` adds one summary of the summaries, and
  `--json` prints a stable shape for other tools.
- **Meeting detection**: one recording is split into the separate meetings it contains,
  combining calendar events, silence gaps, and LLM judgement. Each meeting gets its own
  folder named after the meeting.
- **Speaker attribution**: local voice clustering via sherpa-onnx (~46 MB of ONNX models,
  no PyTorch), then LLM naming from evidence in the conversation. Anonymous labels are
  kept when confidence is low.
- **Structured meeting notes**: summary, themed sections, decisions split by whether the
  room agreed, owner-tagged next steps, and a timestamped walkthrough. Produced in one
  schema-constrained LLM call (Anthropic tool use / OpenAI JSON mode).
- **Voice Activity Detection** (Silero, via `whisper.cpp --vad`), on by default. On a
  3h33m test recording this took the transcript from 2,852 words to 20,762: without it,
  Whisper hallucinated on room tone and locked into a repetition loop after 12 minutes.
- **Timestamped transcripts** with per-segment times and speaker labels.
- **Calendar integration** (macOS EventKit) for real meeting titles and attendee lists.
- **Domain vocabulary is now learned, not maintained.** Whisper's initial prompt is capped
  at 224 tokens, so a hand-kept jargon list cannot grow. The prompt is assembled per
  recording from the calendar event, a glossary mined from past notes, and the configured
  seed, fitted to the budget by priority. Corrections the notes step makes are fed back
  into the glossary, so a term misheard once is primed correctly next time.
- Decoder repetition loops are collapsed. VAD stops a loop propagating for hours, but one
  inside a single speech chunk still got through: a 53-minute meeting ended with the same
  sentence 23 times, and the notes step dutifully summarised it as content. Runs of
  identical consecutive lines are collapsed, and long lines are compared by similarity
  because a loop drifts as it repeats ("We're going to..." becomes "It's going to...").
- Closing chatter is no longer promoted to a meeting of its own. Two minutes of goodbyes
  and lunch plans passed the duration test and got a title, a summary and invented next
  steps. A trailing stretch is now measured on distinct content, not elapsed time, and
  folded back into the meeting it ends.
- **HTML notes output** alongside Markdown and JSON.
- Slack notifications link to the destination folder's storage. Google Drive deep-links to
  the folder; iCloud Drive links to iCloud Drive, because it has no path-addressable web
  URL. `file://` is no longer emitted at all -- Slack does not linkify it, so it rendered
  as dead text. Messages now also carry fallback text, so a phone notification shows the
  meeting title rather than "This content can't be displayed".
- **Per-meeting video clips**, cut losslessly with stream copy.
- `scripts/transcribe-dev` — runs a local checkout alongside the Homebrew release, so
  `transcribe` stays the released build while `transcribe-dev` is the working tree.
  `TRANSCRIBE_DEV_REPO` points it at another checkout or a git worktree.
- **Automatic recording**: `transcribe autorecord` starts and stops an OBS recording as
  meetings begin and end, closing the loop from meeting to notes. A recording needs the
  microphone *and* one corroborating signal, either the camera (CoreMediaIO) or a calendar
  event in progress, because the microphone alone fires on dictation and voice notes.
  Both device signals come from macOS and need no permission. Virtual devices are ignored,
  and debounce either side stops chimes creating files or headset swaps splitting meetings.
- **Menu bar app** (`transcribe menubar`): live signal display plus Record now, Stop, and
  Pause auto-record. A manual instruction skips the debounce and overrides detection, which
  is the only way to capture a meeting attended with camera and microphone off.
- `transcribe setup-autorecord` installs the launchd agent; `transcribe mic` shows which
  inputs are in use.
- `transcribe doctor` — checks tools, models, keys, and permissions.
- `transcribe calendar-check` — grants and verifies macOS Calendar access.
- `--flat`, `--no-split`, and `--no-diarize` flags.
- Optional extras: `transcribe[diarize]`, `transcribe[calendar]`, `transcribe[all]`.
- `openai_base_url` points the `openai` provider at any OpenAI-compatible endpoint — a
  LiteLLM gateway, Ollama, vLLM, LM Studio, OpenRouter.
- `llm_timeout_seconds` and `llm_max_retries`: the SDK defaults (600s x 2 retries) let one
  stalled call hold up a run for half an hour.

### Changed
- Default `whisper_model` is now `large-v3-turbo` (was `base`). Existing configs that set
  the key explicitly are unaffected.
- The watcher now waits for a recording to stop growing before processing it. A recorder
  creates its file when the meeting starts and writes until it ends, so the previous
  fixed 2-second wait could transcribe an incomplete file.
- The source recording is moved only after every meeting has been written.
- `whisper.transcribe_video()` still returns flat text, but transcription now runs through
  whisper's JSON output to preserve timestamps.

### Fixed
- A config with only an Anthropic OAuth token (`anthropic_auth_token`, or an `sk-ant-oat`
  key) passed the "configured" check and then silently skipped every LLM call. Both call
  paths now accept either credential shape.
- Diarization no longer over-segments. The upstream clustering threshold of 0.5 reported
  36 distinct "speakers" in a 15-minute sample of a real meeting; the default is now 0.8,
  which reported a plausible 6. Micro-clusters are dropped proportionally rather than by a
  fixed number of seconds, so the cut behaves the same on a 10-minute call and a 3-hour one.
- Diarization runs ~2.6x faster: the segmentation window shift ratio defaults to 0.25
  rather than the upstream 0.1, which measured 28.9x realtime against 10.9x for the same
  turns. `read_wav_window` also stopped allocating a second full-size copy of the audio.
- A truncated LLM response is now recognised as truncation and retried with a bigger
  budget. Previously, hitting the output cap mid-JSON surfaced as
  `JSONDecodeError: Unterminated string`, which named the wrong cause, and the notes were
  dropped for that meeting.
- "No notes were generated (no LLM provider configured)" was printed and written into the
  notes whenever notes were missing for *any* reason, including a failed call against a
  perfectly good provider. The run output now distinguishes the two, and the notes file no
  longer asserts a cause it cannot know.
- Speaker naming no longer starves itself. It was sent ten minutes of surrounding
  transcript and asked about every voice cluster including near-silent fragments;
  deepseek-v4-pro spent its entire completion budget reasoning and returned nothing on
  every meeting. It now sends only the opening and lines that say a participant's name
  out loud, and only asks about voices with real airtime -- 13k characters down to 3k,
  and an answer in seconds rather than never.
- Reasoning models bill their chain of thought as completion tokens and return *empty*
  content when they exhaust the budget thinking. The output budgets now allow for it, and
  an exhausted budget reports that cause instead of an opaque JSON parse error.
- `VideoHandler.on_created` read the enclosing `config` rather than `self.config`.
- Model directories are resolved per call instead of at import, so they follow `$HOME`.
- Downloaded archives are extracted with member validation, rejecting paths that escape
  the destination and any symlink or hardlink members.

## [2.0.0] - 2025-11-11

### Added
- **Watch Mode**: Monitor directories for new video files with `transcribe watch <directory>`
- **Background Daemon**: Auto-start transcription service with `transcribe setup-daemon`
- **OpenAI Integration**: Automatic summarization of transcripts with timestamps and action items
- **Slack Notifications**: Send formatted notifications when processing completes
- **File Management**: Automatically move processed files to configurable destination (e.g., iCloud)
- **Configuration System**: YAML-based config at `~/.transcribe/config.yaml`
- **Multi-file Output**: Generate transcript + AI summary for each video
- `transcribe config` command to view/edit configuration
- Support for multiple video formats (.mov, .mp4, .avi, .mkv, .m4v)
- Example configuration file (`config.example.yaml`)

### Changed
- Refactored main transcription logic into `process_video_file()` function
- Enhanced output with progress indicators and emoji
- Improved error handling and logging
- Updated README with comprehensive documentation
- Version bumped to 2.0.0 to reflect major feature additions

### Dependencies
- Added `pyyaml>=6.0` for configuration management
- Added `watchdog>=3.0.0` for directory monitoring
- Added `openai>=1.0.0` for AI summarization
- Added `requests>=2.31.0` for Slack notifications

### Technical
- Implemented FileSystemEventHandler for robust file watching
- Added launchd plist generation for macOS daemon support
- Structured code with separate functions for each workflow step
- Added configuration validation and defaults

## [1.0.0] - 2024-10-29

### Added
- Initial release
- Basic video/audio transcription using whisper-cpp
- Command-line interface: `transcribe <video_file>`
- Automatic audio extraction from video files
- Transcript saved as text file alongside original video
- Support for local Whisper model (ggml-base.bin)
- Homebrew tap formula for easy installation

### Requirements
- macOS
- Python 3.9+
- whisper-cpp
- ffmpeg
