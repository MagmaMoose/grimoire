# Architecture

How Transcribe turns a recording into meeting notes, how data flows, and how the package
is structured.

> macOS only.

## Pipeline overview

```
User saves a recording to ~/Movies
        │
        ▼
launchd daemon (or `transcribe watch`) sees the new file
and waits for it to stop growing (a recorder writes for the whole meeting)
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Local transcription                                      │
│    video ──ffmpeg──► 16 kHz mono wav                        │
│          ──whisper-cpp + Silero VAD──► timestamped segments │
│    Privacy: fully local, nothing uploaded                   │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Meeting detection                                        │
│    calendar events ─┐                                       │
│    silence gaps ────┼──► one or more Meetings               │
│    LLM judgement ───┘                                       │
└─────────────────────────────────────────────────────────────┘
        │
        ▼  (per meeting)
┌─────────────────────────────────────────────────────────────┐
│ 3. Speaker attribution                                      │
│    audio window ──sherpa-onnx──► voice clusters             │
│    clusters + transcript + attendees ──LLM──► real names    │
│    Privacy: clustering is local; only text reaches the LLM  │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Notes generation                                         │
│    transcript ──LLM (one schema-constrained call)──►        │
│      title, summary, sections, decisions, next steps,       │
│      timestamped details                                    │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. Filing                                                   │
│    destination/<date> <meeting title>/                      │
│      notes.md, notes.html, notes.json, transcript.txt,      │
│      summary.txt, and this meeting's video clip             │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 6. Notification (if Slack is configured)                    │
│    Title, summary, next steps, folder link → Slack          │
└─────────────────────────────────────────────────────────────┘
```

The source recording is moved only after every meeting has been written, so a failure
part-way through never loses the original.

## Why Voice Activity Detection is not optional in practice

A long recording is rarely *digitally* silent when nobody speaks — there is a floor of
room tone, fans, and open microphones, typically around −33 dBFS. Whisper transcribes that
floor as filler, and once it emits the same token often enough it can enter a repetition
loop that persists for the rest of the file.

Measured on a 3h33m recording:

| | Segments | Words | Result |
| --- | --- | --- | --- |
| Without VAD | 634 | 2,852 | Real text for 12 min, then `Thank you.` every 30s for 3 hours |
| With VAD | 1,050 | 20,762 | Content throughout |

`whisper.cpp` runs Silero VAD (`--vad`), which both skips non-speech and resets decoder
state per speech chunk so a loop cannot propagate. `whisper_vad` defaults to `true`.

## Domain vocabulary

Whisper's initial prompt is capped at `n_text_ctx / 2` = 224 tokens, so a domain
vocabulary cannot accumulate globally: every term added crowds out another. `vocabulary.py`
selects one per recording instead, from the calendar event (most specific), the configured
seed, then a glossary ranked from terms recurring in past `notes.json` files, fitted to the
budget so the most generic entries are dropped first.

`notes.apply_corrections` closes the loop. The notes call already reads the whole transcript
and infers that a garbled word was "Kubernetes"; reporting that explicitly lets the stored
transcript be repaired and the term recorded in `~/.transcribe/glossary.json`, weighted
above passively-mined terms. A word misheard once is primed correctly the next time.

## Meeting detection

`segmentation.split_into_meetings()` combines three signals, each falling back to the next:

1. **Calendar** (`calendars.py`). Events overlapping the recording give boundaries, titles,
   and attendees. An event with no speech within 10 minutes of its start is ignored, so a
   declined or unrecorded invite cannot manufacture an empty meeting.
2. **Silence gaps.** Pauses of at least `meeting_gap_seconds` are candidate boundaries.
3. **The LLM.** It reads the transcript and decides which candidates are real, and names
   whatever meetings result.

Back-to-back calls frequently have no silence between them at all — on the 3.5-hour
recording used for testing, the largest gap in speech was **17 seconds** across four
meetings. What survives is the language at the seam. So when the transcript fits the token
budget it is sent in full rather than sampled, and `TRANSITION_PHRASES` additionally
nominates sign-off and greeting passages for inclusion when it does not.

## Speaker attribution

`diarize.py` uses sherpa-onnx with two ONNX models:

- `sherpa-onnx-pyannote-segmentation-3-0` (~6 MB) finds speech turns.
- `nemo_en_titanet_small.onnx` (~40 MB) embeds each turn as a voice fingerprint.

Embeddings are clustered (fixed count when the attendee list is known, otherwise
threshold-based), micro-clusters from crosstalk are dropped, and each transcript segment
takes the speaker it overlaps most. Segments with no overlapping turn stay unattributed
rather than being forced onto a neighbour.

Naming happens separately in `notes.resolve_speaker_names()`: the LLM maps each cluster to
a person using evidence in the conversation, and returns confidence. Only `high` and
`medium` are applied — a wrong name in the notes is worse than no name.

Audio is read one meeting-sized window at a time (`read_wav_window`), keeping memory
bounded; a full 3-hour recording as float32 would be ~800 MB.

## Structured output

Notes need a fixed shape, so the schema is enforced by the provider rather than parsed out
of prose:

- **Anthropic** — a forced tool call whose `input_schema` is the notes schema.
- **OpenAI** — JSON mode, with the schema also spelled out inline (JSON mode guarantees
  valid JSON, not schema conformance).

Both are reached through `llm.complete_json()`, which returns `None` on any failure so the
pipeline continues without that artifact.

`openai_base_url` points the OpenAI path at any compatible endpoint — a LiteLLM gateway,
Ollama, vLLM, OpenRouter — so a self-hosted or local model needs no code change.

Reasoning models are the one sharp edge: they bill their chain of thought as completion
tokens and return **empty content** with `finish_reason="length"` if they exhaust the
budget thinking. `_openai_complete_json` raises a message naming that cause rather than
letting it surface as an opaque JSON parse error, and the default budgets
(`boundary_max_tokens`, `speaker_max_tokens`, `notes_max_tokens`) leave room for it.

## Data flow

```
recording.mov
    │
    ├─ media.recording_started_at()  ── container metadata / filename / mtime ─► wall clock
    ├─ media.probe_duration()
    │
    ▼
whisper.transcribe_video_segments()  ── ffmpeg + whisper-cli (local) ──► [Segment]
    │                                                                     + shared wav
    ▼
calendars.events_for_recording()  ── EventKit ──► [event]
    │
    ▼
segmentation.split_into_meetings()  ──► [Meeting]
    │
    ├─ diarize.diarize_meeting()      ── sherpa-onnx (local) ──► segment.speaker
    ├─ notes.resolve_speaker_names()  ── LLM ──► real names
    ├─ notes.generate_notes()         ── LLM ──► notes dict
    │
    ▼
render.render_markdown() / render_html() / render_transcript()
    │
    ▼
processing._write_meeting_outputs()  ──► destination/<date> <title>/
    │
    ▼
slack.send_slack_notification()
```

## Domain vocabulary

Whisper's initial prompt is capped at `n_text_ctx / 2` = 224 tokens, so a domain
vocabulary cannot accumulate globally: every term added crowds out another. `vocabulary.py`
selects one per recording instead, from the calendar event (most specific), the configured
seed, then a glossary ranked from terms recurring in past `notes.json` files, fitted to the
budget so the most generic entries are dropped first.

`notes.apply_corrections` closes the loop. The notes call already reads the whole transcript
and infers that a garbled word was "Kubernetes"; reporting that explicitly lets the stored
transcript be repaired and the term recorded in `~/.transcribe/glossary.json`, weighted
above passively-mined terms. A word misheard once is primed correctly the next time.

## Meeting detection

`audio.py` reads CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` for every
device with an input stream. This is the signal behind the menu-bar microphone indicator,
so it covers any application without per-app integration, and reading it requires no
microphone permission.

Virtual and loopback devices (Steam, BlackHole, Loopback, Krisp, aggregate devices) are
filtered out: several report as running whenever their host application is open, which
would otherwise mean recording constantly.

`camera.py` is the video twin, reading CoreMediaIO's
`kCMIODevicePropertyDeviceIsRunningSomewhere`.

`meeting_in_progress` combines them. The microphone is necessary but never sufficient,
because dictation and voice notes use it too; a recording needs the mic plus either the
camera or a calendar event in progress. A meeting attended with both devices off is not
detectable by any of this, which is what the menu bar's manual override exists for.

`autorecord.MeetingRecorder` turns that boolean into start/stop decisions. It holds no
clock and does no sleeping — `update(now, mic_active, free_gb)` is handed the time — so the
debounce logic is tested directly rather than through timing. Recording will not start
below `autorecord_min_free_gb`, since a truncated file on a full disk loses the meeting,
but a low disk never stops a recording already in progress, which would lose what has
already been captured.

## Execution modes

```
One-off:   transcribe video.mov [--no-split] [--flat] [--json]
             └─► process_video_file() ─► process_recording()

Watch:     transcribe watch ~/Movies
             └─► watchdog Observer ─► VideoHandler.on_created
                   ─► wait_until_stable() ─► process_video_file()

Daemon:    launchd ─► transcribe watch <watch_directory> (at login)
             └─► same Observer loop, KeepAlive + RunAtLoad
```

`wait_until_stable()` polls file size until it stops growing. A recorder creates its file
when the meeting *starts* and writes until it ends, so the creation event can arrive hours
before the recording is complete.

## Error handling

Every optional stage degrades rather than failing the run:

| Failure | Result |
| --- | --- |
| Local transcription fails | Error, that file is skipped |
| `sherpa-onnx` / `numpy` missing | Warning, notes have no speaker attribution |
| Calendar unavailable or denied | Note, titles come from the transcript instead |
| No LLM key | Transcript and speakers are still written; no notes |
| LLM call fails | Warning, that artifact is skipped |
| Video cut fails | Warning, notes are still written |
| Source move fails | Warning, files stay in the watch directory |
| Slack fails | Warning, everything is already on disk |

All daemon output goes to `~/Library/Logs/transcribe.log` and `transcribe.error.log`.

## Package layout

```
src/transcribe/
├── __init__.py      # package metadata / __version__
├── __main__.py      # `python -m transcribe`
├── cli.py           # argument parsing, dispatch, doctor, calendar-check
├── config.py        # load/save ~/.transcribe/config.yaml + DEFAULT_CONFIG
├── audio.py         # CoreAudio: which inputs are in use (meeting detection)
├── autorecord.py    # meeting detection state machine, drives OBS
├── camera.py        # CoreMediaIO: which cameras are in use
├── menubar.py       # menu bar app: manual override and signal visibility
├── media.py         # ffmpeg/ffprobe: probe, extract audio, lossless cut
├── vocabulary.py    # assembles the whisper prompt from calendar + mined glossary
├── segments.py      # Segment and Meeting data model
├── whisper.py       # transcription with VAD, timestamped segments, model download
├── diarize.py       # sherpa-onnx speaker clustering and attribution
├── calendars.py     # EventKit lookup; registry for future sources
├── segmentation.py  # meeting boundary detection
├── notes.py         # notes generation and speaker naming (LLM)
├── llm.py           # provider dispatch, text and schema-constrained calls
├── render.py        # Markdown / HTML / transcript renderers
├── processing.py    # pipeline orchestration and filing
├── watch.py         # watchdog directory watcher, file-stability wait
├── daemon.py        # launchd plist generation
├── links.py         # resolves a linkable URL for a destination folder
├── slack.py         # Slack webhook / bot-token notifications
├── gdrive.py        # optional Google Drive folder URL resolution
├── voicememos.py    # read/import recordings from the macOS Voice Memos app
├── permissions.py   # identify the responsible .app for macOS permission prompts
└── tls.py           # TLS CA bundle fixup for frozen binaries
```

Other paths:

```
~/.transcribe/config.yaml                              # user configuration
~/.transcribe/models/                                  # diarization ONNX models
~/.whisper-models/ggml-<model>.bin                     # whisper + VAD models
~/Library/LaunchAgents/com.calebsargeant.transcribe.plist  # daemon definition
~/Library/Logs/transcribe.log, transcribe.error.log    # daemon logs
```

## Dependencies

Runtime (required):

- `pyyaml` — config parsing
- `watchdog` — directory monitoring
- `anthropic`, `openai` — summarization providers
- `requests` — Slack notifications

Optional extras:

| Extra | Packages | Purpose |
| --- | --- | --- |
| `diarize` | `sherpa-onnx`, `numpy` | Speaker attribution |
| `calendar` | `pyobjc-framework-EventKit` | Meeting titles and attendees |
| `gdrive` | `google-auth`, `google-api-python-client` | Drive folder links |

System (Homebrew): `whisper-cpp`, `ffmpeg`.

## Security considerations

1. **API keys** live in plaintext in `~/.transcribe/config.yaml`, which is created `0600`
   inside a `0700` directory. Do not commit it.
2. **Slack webhook / bot token** are secrets — keep them out of version control.
3. **Video privacy** — audio and video are processed locally; only the text transcript is
   sent to the LLM provider, and only when a key is configured.
4. **Model names** from config are validated against an allowlist before being used to
   build a URL or a filesystem path, preventing path traversal.
5. **Downloaded archives** are extracted with member validation, rejecting paths that
   escape the destination and any symlink or hardlink members.
6. **Filenames** are absolutised before being passed to `ffmpeg`/`whisper-cli`, so a file
   whose name begins with `-` cannot be parsed as an option.
7. **Meeting titles** are sanitised before use as folder names.
8. **Calendar access** is read-only and requires explicit macOS permission.
9. **Network calls** — Anthropic/OpenAI, Slack, Hugging Face and GitHub model downloads are
   all over HTTPS/TLS.
