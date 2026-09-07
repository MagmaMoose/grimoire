# Transcribe

Local, open-source meeting notes for macOS. Drop a recording in a folder and get back
the transcript, a structured set of notes, and per-meeting folders — without the
recording ever leaving your machine.

> macOS only. Tested on Apple Silicon and Intel Macs.

## What it does

A new recording lands in your watch folder. Transcribe then:

1. **Transcribes it locally** with `whisper-cpp`. Nothing is uploaded.
2. **Splits it into meetings.** One recording left running across a morning usually holds
   several unrelated calls; each becomes its own meeting.
3. **Works out who spoke**, clustering voices locally and naming them from the
   conversation and your calendar.
4. **Writes the notes** — summary, themed sections, decisions, owner-tagged next steps,
   and a timestamped walkthrough of what was said.
5. **Files everything** in one folder per meeting, named after the meeting.
6. **Tells you** on Slack, if you want.

### Output

One folder per meeting, in your destination directory:

```
Meetings/
├── 2026-04-14 1000 Checkout latency and Q3 rollout/
│   ├── notes.md                 # the notes, in Markdown
│   ├── notes.html               # the same notes as a standalone page
│   ├── notes.json               # machine-readable: notes + every segment
│   ├── transcript.txt           # timestamped, grouped by speaker
│   ├── summary.txt              # the one-paragraph summary on its own
│   └── 2026-04-14 1000 ....mov  # this meeting's slice of the recording
└── 2026-04-14 1130 Design review/
    └── ...
```

`notes.md` follows the structure you'd expect from a hosted meeting assistant:

```markdown
# Checkout latency and Q3 rollout

**Date:** Tuesday, 14 April 2026, 10:00
**Duration:** 45 minutes
**Invited:** Sam Okoro, Priya Nair, Alex Whitfield

## Summary
The team traced checkout latency to an unindexed query and agreed a rollout order for Q3.

### Latency investigation
Median checkout time had roughly doubled since the March release. The cause was a missing
index on the orders table, added behind a migration.

## Decisions
### Aligned
- **Ship the index this week** - The migration goes out ahead of the Q3 work.
### Needs further discussion
- **Whether to split the service** - Raised, but nobody committed to a direction.

## Next steps
- **[Priya Nair] Add the orders index** - Ship the migration and confirm the median drops.

## Details
- **Reproducing the slowdown:** Sam walked through the traces. (00:06:27)
```

## Quick start

### Homebrew (macOS)

```bash
brew tap MagmaMoose/tap && brew install transcribe
```

### pip

```bash
pip install 'transcribe[diarize,calendar]'
```

### Configuration

```bash
transcribe config
```

Add an API key to `~/.transcribe/config.yaml` (`anthropic_api_key`, or `openai_api_key`
with `llm_provider: openai`), then:

```bash
transcribe doctor
```

```bash
transcribe ~/Movies/meeting.mov
```

Models download themselves on first use. For step-by-step setup, see
[Installation](install.md).

## Features

- **Meeting detection**: One recording is split into the separate meetings it contains,
  combining calendar events, silence gaps, and LLM judgement. Each meeting gets its own
  folder named after the meeting.
- **Speaker attribution**: Local voice clustering via sherpa-onnx (~46 MB of ONNX models,
  no PyTorch), then LLM naming from evidence in the conversation. Anonymous labels are
  kept when confidence is low.
- **Structured meeting notes**: Summary, themed sections, decisions split by whether the
  room agreed, owner-tagged next steps, and a timestamped walkthrough. Produced in one
  schema-constrained LLM call.
- **Voice Activity Detection** (Silero, via `whisper.cpp --vad`), on by default.
- **Timestamped transcripts** with per-segment times and speaker labels.
- **Calendar integration** (macOS EventKit) for real meeting titles and attendee lists.
- **Domain vocabulary** learned from past notes and calendar events.
- **HTML notes output** alongside Markdown and JSON.
- **Slack notifications** with meeting summaries and links to output folders.
- **Per-meeting video clips**, cut losslessly with stream copy.
- **Automatic recording**: `transcribe autorecord` starts and stops OBS recording as
  meetings begin and end.
- **Menu bar app**: Manual override and a view of what the detector can see.

## Requirements

- macOS 12+
- Python 3.11+
- `ffmpeg` and `ffprobe` (via `brew install ffmpeg`)
- `whisper-cpp` (via `brew install whisper-cpp`)
- LLM API key (Anthropic or OpenAI)

## License

MIT
