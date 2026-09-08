# Transcribe

Local, open-source meeting notes for macOS. Drop a recording in a folder and get back
the transcript, a structured set of notes, and per-meeting folders — without the
recording ever leaving your machine.

[Issues](https://github.com/CalebSargeant/transcribe/issues) ·
[Releases](https://github.com/CalebSargeant/transcribe/releases) ·
[Docs](docs/)

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

## Quickstart

```bash
brew tap MagmaMoose/tap && brew install transcribe
```

```bash
pip install 'transcribe[diarize,calendar]'
```

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

Models download themselves on first use. For step-by-step setup see
**[docs/install.md](docs/install.md)**.

### Running a local checkout

Homebrew installs a frozen build, which is what you want day to day and useless while
changing the code. `scripts/transcribe-dev` runs the working tree instead, so `transcribe`
stays the released version and `transcribe-dev` is whatever you are editing:

```bash
ln -sf "$PWD/scripts/transcribe-dev" ~/.local/bin/transcribe-dev
```

```bash
transcribe-dev doctor
```

It resolves the checkout from the symlink's own location. To point it at a git worktree
instead, set `TRANSCRIBE_DEV_REPO`:

```bash
TRANSCRIBE_DEV_REPO=~/repos/transcribe/.claude/worktrees/my-branch transcribe-dev meeting.mov
```

### Recording meetings automatically

`transcribe autorecord` starts an OBS recording when a meeting begins and stops it when it
ends, which closes the loop: the recording lands in your watch directory and the daemon
transcribes it.

**The microphone alone is not enough.** Dictation, voice notes and Siri all hold the
microphone and none of them are meetings, so recording on that signal alone means recording
constantly. A recording needs the microphone *and* one corroborating signal:

| Signal | Precision | Catches |
| --- | --- | --- |
| mic + **camera on** | very high | video calls; almost nothing else turns the camera on |
| mic + **calendar meeting now** | high | scheduled meetings, including camera-off standups |
| mic alone (`autorecord_mic_only`) | low, opt-in | everything, including things you don't want |

Both device signals come from macOS itself: CoreAudio's
`kAudioDevicePropertyDeviceIsRunningSomewhere` and the CoreMediaIO equivalent, which are
what the menu bar microphone and camera indicators read. That means any app works, a Meet
tab in a browser as much as Zoom, with no per-app integration, and neither read needs a
permission because checking is not capturing.

**One case is genuinely undetectable**: a meeting you join with your camera and microphone
both off. Nothing short of watching the conferencing app itself can see that, which is why
there is a menu bar with a manual override.

Virtual devices are filtered out (Steam, BlackHole, Loopback, Krisp, OBS Virtual Camera,
Continuity Desk View), since several report as running whenever their host app is open.

```bash
transcribe mic
```

shows every input and camera, what is in use, and whether that combination would record.
It is the quickest way to see why a meeting was or was not picked up.

### The menu bar

```bash
pip install 'transcribe[menubar]'
```

```bash
transcribe menubar
```

The title is the status: `●` recording, `○` meeting detected, `◌` idle, `⊘` auto-record
paused. The menu shows the live signals and offers **Record now**, **Stop recording**, and
**Pause auto-record**. A manual instruction skips the debounce and overrides detection,
because an explicit "record this" should not be second-guessed.

### Setup

Enable **OBS > Tools > WebSocket Server Settings**, put the password in
`~/.transcribe/config.yaml` as `obs_password`, then either run `transcribe menubar`, or
install the headless agent:

```bash
transcribe setup-autorecord
```

Recordings are roughly 500 MB per hour, so watch the disk. `autorecord_min_free_gb` refuses
to start below a threshold rather than writing a truncated file, though it will never
interrupt a recording already running. Recording other people has consent and
data-protection implications that vary by jurisdiction, and automation removes the moment
where you would otherwise decide.

## Commands

```bash
transcribe meeting.mov              # process one recording
transcribe meeting.mov --no-split   # treat it as a single meeting
transcribe meeting.mov --flat       # legacy: one transcript, one summary, no meetings
transcribe watch ~/Movies           # watch a folder in the foreground
transcribe setup-daemon             # install the launchd agent (runs at login)
transcribe doctor                   # check tools, models, keys, permissions
transcribe calendar-check           # grant and verify macOS Calendar access
transcribe config                   # show configuration and its location
transcribe autorecord               # record meetings automatically via OBS
transcribe setup-autorecord         # install the auto-record launchd agent
transcribe menubar                  # menu bar app with a manual override
transcribe mic                      # show inputs, cameras, and whether it would record
transcribe voicememos               # list recent Voice Memos recordings
transcribe voicememos --import      # import Voice Memos through the notes pipeline
```

## How the pieces work

### Transcription, and why VAD is on by default

Recordings are rarely silent when nobody is talking — there's a noise floor of room tone,
fans, and open mics. Fed that, Whisper hallucinates filler and can fall into a repetition
loop it never recovers from, turning hours of audio into `Thank you.` on repeat.

Silero VAD skips non-speech and resets decoder state per speech chunk, which contains the
damage. On a real 3.5-hour recording, enabling it took the transcript from 2,852 words to
20,762. Leave `whisper_vad` on.

### Domain vocabulary, without a list to maintain

Whisper takes an initial prompt that biases the decoder toward specific words, which is
what stops "Kubernetes" becoming "humanitis". But it is **capped at 224 tokens**, so a
global jargon list cannot grow: every term added crowds out another. The prompt is
therefore assembled per recording, from three sources in priority order:

1. **The calendar event** — its title and attendee names. A call titled "Janeway hosting
   review" primes "Janeway" with nobody typing anything.
2. **A glossary mined from your own past notes** in the destination folder. Terms that
   recur across meetings are your domain vocabulary, by definition.
3. **The `whisper_prompt` seed**, for terms that never appear in text on their own.

The loop that closes it: when the notes step infers that a garbled word was really
"Kubernetes", it reports that correction. The transcript is repaired, and the term is
added to the glossary, so next time the decoder is primed with it rather than mishearing
it again. Nobody edits a config file.

Set `whisper_auto_prompt: false` to go back to using `whisper_prompt` verbatim.

The default model is `large-v3-turbo` (~1.6 GB, downloaded once). Set `whisper_model: base`
if you'd rather have something small and fast.

### Splitting one recording into several meetings

Three signals, in order of trust:

1. **Calendar events** overlapping the recording — authoritative, and they carry real
   titles and attendees.
2. **Silence gaps** between speech.
3. **The LLM**, reading the transcript for sign-offs, greetings, changes of participant,
   and changes of subject.

Back-to-back calls often have *no* silence between them, so the wording at the seam
("thanks everyone" followed by a different conversation) is frequently the only evidence
a boundary exists. That's why the transcript itself is sent, not just a sample.

Each signal degrades to the next, so this works with no calendar and no API key — it just
gets less precise. With `--no-split` the recording stays one meeting.

### Speaker attribution

A screen recording gives one mixed mono track, so speakers are recovered from the audio.
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) clusters voices using two small ONNX
models (~46 MB, no PyTorch, no gated downloads), producing `Speaker 1`, `Speaker 2`, and
so on.

Those anonymous labels are then matched to real names using the conversation itself —
introductions, people addressing each other, handovers — narrowed by the calendar's
attendee list or your `known_participants`. **Labels stay anonymous when the evidence is
weak**, because a wrong name in the notes is worse than no name.

### Calendar

Reading your calendar gives real meeting titles, real attendee names (which sharpen
speaker naming a lot), and true boundaries. The macOS source reads whatever accounts
Calendar.app already syncs, Google and Exchange included, so there's no second OAuth flow.

macOS asks for permission the first time. A launchd daemon has no UI to show that prompt,
so grant it once interactively:

```bash
transcribe calendar-check
```

Direct Google Calendar and Microsoft 365 sources are
[tracked as issues](https://github.com/CalebSargeant/transcribe/issues).

## Configuration

Configuration lives in `~/.transcribe/config.yaml`. A fully documented template is in
[`config.example.yaml`](config.example.yaml).

| Key | Default | Notes |
| --- | --- | --- |
| `watch_directory` | `~/Movies` | Where new recordings appear. |
| `destination_directory` | iCloud Movies | One folder per meeting is created here. iCloud Drive and Google Drive are both recognised. |
| `llm_provider` | `claude` | `claude` (Anthropic) or `openai`. |
| `anthropic_api_key` | _(empty)_ | Required when provider is `claude`. |
| `anthropic_model` | `claude-haiku-4-5-20251001` | Anthropic model id. |
| `openai_base_url` | _(empty)_ | Point the `openai` provider at any OpenAI-compatible endpoint. |
| `whisper_model` | `large-v3-turbo` | Auto-downloaded. `base` is smaller and faster. |
| `whisper_vad` | `true` | Leave on. See above. |
| `whisper_prompt` | _(empty)_ | Biases the decoder toward your jargon. |
| `meeting_mode` | `true` | `false` restores the original flat behaviour. |
| `split_meetings` | `true` | Detect multiple meetings in one recording. |
| `split_video` | `true` | Cut a per-meeting clip (lossless stream copy). |
| `meeting_gap_seconds` | `180` | Pause length that flags a candidate boundary. |
| `diarization_enabled` | `true` | Needs `transcribe[diarize]`. |
| `known_participants` | `[]` | Names to prefer when identifying speakers. |
| `calendar_enabled` | `true` | Needs `transcribe[calendar]` and permission. |

If no API key is set, summarization is skipped gracefully — you still get the transcript
and the speaker-attributed segments.

### Using a gateway or a local model

`openai_base_url` points the `openai` provider at anything that speaks the OpenAI API — a
LiteLLM gateway, Ollama, vLLM, LM Studio, OpenRouter:

```yaml
llm_provider: openai
openai_base_url: https://litellm.example.com   # or http://localhost:11434/v1 for Ollama
openai_api_key: sk-your-gateway-key
openai_model: deepseek-v4-pro
```

**Reasoning models need bigger output budgets.** They bill their chain of thought as
completion tokens and return *empty* content if they exhaust the budget thinking, so
`boundary_max_tokens`, `speaker_max_tokens`, and `notes_max_tokens` default to 8k/8k/16k.
You are only charged for what is actually generated. If notes come back empty, raise them.

## Optional extras

| Extra | Installs | Enables |
| --- | --- | --- |
| `diarize` | `sherpa-onnx`, `numpy` | Speaker attribution |
| `calendar` | `pyobjc-framework-EventKit` | Meeting titles and attendees from Calendar |
| `gdrive` | `google-auth`, `google-api-python-client` | Google Drive folder links in Slack |
| `all` | all of the above | |

Everything degrades gracefully: a missing extra disables its feature and prints a note,
it never fails the run.

### Links in Slack

Google Drive exposes folder ids through its API, so a notification deep-links straight to
the meeting's folder. **iCloud Drive has no path-addressable web URL** — a share link is
minted by a person sharing an item, and no API can create one — so the link goes to iCloud
Drive itself and the folder path is shown beside it.

`file://` is never emitted: Slack does not linkify it, so it renders as dead text.

## Privacy

- Transcription and speaker attribution run **entirely locally**. Video and audio never
  leave your machine.
- Only the **text transcript** is sent to the LLM provider, and only if a key is set.
- Set `llm_provider` to nothing (or leave the key empty) for a fully offline pipeline that
  still produces transcripts with speaker labels.

## Documentation

- [docs/install.md](docs/install.md) — install, API keys, Slack, Google Drive, troubleshooting.
- [docs/daemon.md](docs/daemon.md) — daemon setup, logs, testing.
- [docs/architecture.md](docs/architecture.md) — pipeline, data flow, modules, security.
- [docs/release.md](docs/release.md) — release and Homebrew-tap process.
- [CHANGELOG.md](CHANGELOG.md) — version history.

## License

MIT — see [LICENSE](LICENSE).
