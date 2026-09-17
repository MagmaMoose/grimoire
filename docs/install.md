# Installation & Configuration

Full setup for Transcribe: install, configure API keys, optional Slack and Google Drive
links, plus upgrade, uninstall, and troubleshooting.

> macOS only. Tested on macOS 14+ (Apple Silicon and Intel).

For a 5-minute version, the [README quickstart](../README.md#quickstart) is enough. This
guide covers everything in detail.

## Prerequisites

- macOS with [Homebrew](https://brew.sh)
- An Anthropic (Claude) API key — default LLM provider — or an OpenAI key (optional, for
  summaries)
- A Slack webhook URL or bot token (optional, for notifications)
- Google Cloud credentials (optional, for Google Drive links in Slack)

## 1. Install via Homebrew

The Homebrew tap lives under **MagmaMoose**.

```bash
brew tap MagmaMoose/tap
brew install transcribe
# equivalently, without tapping first:
brew install magmamoose/tap/transcribe
```

`whisper-cpp` and `ffmpeg` are installed automatically as dependencies.

## 1a. Running a local checkout

Homebrew installs a frozen PyInstaller build. To run the code you are editing without
disturbing it, symlink the dev shim once:

```bash
ln -sf "$PWD/scripts/transcribe-dev" ~/.local/bin/transcribe-dev
```

`transcribe` is then the released version and `transcribe-dev` is your working tree.
`TRANSCRIBE_DEV_REPO` points it at a different checkout or a git worktree:

```bash
TRANSCRIBE_DEV_REPO=/path/to/worktree transcribe-dev doctor
```

It needs [uv](https://docs.astral.sh/uv/) and uses the checkout's own virtualenv, so
optional extras installed there are picked up automatically.

### If `brew install` leaves no `transcribe` command

The token `transcribe` collides with the unrelated **Transcribe!** cask (a commercial
music-transcription app). When that cask is installed, Homebrew declines to link the
formula and prints `transcribe cask is installed, skipping link`. Force the link:

```bash
brew link --overwrite magmamoose/tap/transcribe
```

The cask only installs an `.app`, so there is no actual binary conflict.

## 1b. Optional features

Speaker attribution and calendar lookup are optional Python extras. Install them into the
same interpreter the `transcribe` command uses:

```bash
pip install 'transcribe[diarize,calendar]'
```

| Extra | Installs | Enables |
| --- | --- | --- |
| `diarize` | `sherpa-onnx`, `numpy` | Telling speakers apart (~46 MB of models, no PyTorch) |
| `calendar` | `pyobjc-framework-EventKit` | Meeting titles and attendee lists from Calendar |
| `gdrive` | `google-auth`, `google-api-python-client` | Google Drive folder links in Slack |
| `all` | all of the above | |

Everything degrades gracefully: a missing extra disables its feature and prints a note, it
never fails the run. Check what is active with:

```bash
transcribe doctor
```

## 2. Whisper model (automatic)

The Whisper ggml model is **downloaded automatically** the first time you transcribe, to
`~/.whisper-models/ggml-<model>.bin`. No manual download step is needed.

The model is chosen by the `whisper_model` config key (default `base`):

| Model | Size | Notes |
| --- | --- | --- |
| `tiny` | ~75 MB | Fastest, lowest quality |
| `base` | ~142 MB | Good balance (default) |
| `small` | ~466 MB | Better quality, slower |
| `medium` | ~1.5 GB | High quality, much slower |
| `large-v3` | ~3 GB | Best quality, slowest |
| `large-v3-turbo` | ~1.6 GB | Near-large quality, much faster |

To pre-fetch a model manually (optional):

```bash
mkdir -p ~/.whisper-models
curl -L -o ~/.whisper-models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

## 3. Create and edit the config

```bash
transcribe config            # creates ~/.transcribe/config.yaml
open ~/.transcribe/config.yaml
```

Example configuration:

```yaml
# Where to watch for new video files
watch_directory: /Users/you/Movies

# Where processed files are moved (a folder is created per video)
destination_directory: /Users/you/Library/Mobile Documents/com~apple~CloudDocs/Movies

# LLM provider: "claude" (default) or "openai"
llm_provider: claude

# Anthropic (Claude) — used when llm_provider is "claude"
anthropic_api_key: sk-ant-your-key-here
anthropic_model: claude-haiku-4-5-20251001

# OpenAI — used when llm_provider is "openai"
openai_api_key: sk-your-key-here
openai_model: gpt-4o-mini

# Slack (optional): webhook URL, or bot token + channel id
slack_webhook_url: https://hooks.slack.com/services/YOUR/WEBHOOK/URL
# slack_bot_token: xoxb-your-bot-token
# slack_channel_id: C01234567890

# Video file extensions to watch
video_extensions:
  - .mov
  - .mp4
  - .avi
  - .mkv
  - .m4v

# Whisper model name (ggml-<name>.bin); auto-downloaded if missing
whisper_model: large-v3-turbo

# Optional iCloud base URL for links in Slack messages
icloud_base_url: https://www.icloud.com/iclouddrive/
```

If no key is set for the selected provider, summarization is skipped gracefully and you
still get the transcript.

## 4. Choose an LLM provider

Transcribe defaults to **Claude**. Set `llm_provider` to switch.

### Claude (default)

1. Get a key from <https://console.anthropic.com/>.
2. Set `anthropic_api_key` in the config.
3. Leave `llm_provider: claude` (the default). Adjust `anthropic_model` if desired
   (default `claude-haiku-4-5-20251001`).

### OpenAI (alternative)

1. Get a key from <https://platform.openai.com/api-keys> and add billing at
   <https://platform.openai.com/account/billing>.
2. Set `llm_provider: openai` and `openai_api_key`.
3. Adjust `openai_model` if desired (default `gpt-4o-mini`).

**Cost:** roughly $0.01–0.05 per video for summarization, depending on length and model.

### A gateway, or a local model

`openai_base_url` points the `openai` provider at anything speaking the OpenAI API:

```yaml
llm_provider: openai
openai_base_url: https://litellm.example.com   # LiteLLM gateway
# openai_base_url: http://localhost:11434/v1   # Ollama
openai_api_key: sk-your-gateway-key
openai_model: deepseek-v4-pro
```

Reasoning models bill their chain of thought as completion tokens and return empty content
if they run out mid-thought. The defaults (`boundary_max_tokens: 8000`,
`speaker_max_tokens: 8000`, `notes_max_tokens: 16000`) allow for this; raise them if notes
come back empty. You are only charged for tokens actually generated.

## 4b. Calendar access (optional)

Reading your calendar gives real meeting titles and attendee names. Attendee names matter
more than they sound: they let speaker attribution pin the number of voices and give the
naming step a roster to match against.

The macOS source reads whatever accounts Calendar.app already syncs — Google and Exchange
included — so there is no second sign-in.

macOS asks for permission the first time. **A launchd daemon has no UI to show that
prompt**, so grant it once from a normal terminal:

```bash
transcribe calendar-check
```

Approve the prompt. The command then lists your next few events to confirm it works. If
you see `access denied`, enable Transcribe (or your terminal) under **System Settings →
Privacy & Security → Calendars** and run it again.

If no events are listed, check that Calendar.app actually has your accounts added — a
Google Calendar used only in a browser will not appear.

Direct Google Calendar and Microsoft 365 sources are tracked as
[issue #4](https://github.com/CalebSargeant/transcribe/issues/4) and
[issue #5](https://github.com/CalebSargeant/transcribe/issues/5).

## 5. Slack notifications (optional)

Choose **one** method.

### Method A — Webhook URL (simpler)

1. Go to <https://api.slack.com/apps> → **Create New App** → **From scratch**.
2. Name it "Transcribe" and select your workspace.
3. **Features → Incoming Webhooks → Activate**.
4. **Add New Webhook to Workspace** → select a channel.
5. Copy the webhook URL into `slack_webhook_url`.

### Method B — Bot token (more features)

1. Create an app as above.
2. **OAuth & Permissions → Bot Token Scopes**, add `chat:write` and `chat:write.public`.
3. **Install to Workspace** and copy the **Bot User OAuth Token** (`xoxb-...`).
4. Get the channel id from the channel URL (e.g. `C01234567890`).
5. Set `slack_bot_token` and `slack_channel_id`.

## 6. Google Drive links in Slack (optional)

If your destination directory is a Google Drive folder, Slack notifications can link to the
Drive folder instead of a `file://` path.

```bash
brew install google-cloud-sdk
gcloud auth application-default login   # follow the browser prompts
```

This requires the optional `gdrive` extra (already bundled in the Homebrew binary). If you
skip this, notifications fall back to `file://` links, which work for local access.

**Re-authentication** is needed roughly every 6 months, or when the refresh token expires.

## Running

### One-off transcription

```bash
transcribe /path/to/video.mov
transcribe /path/to/video.mov --json   # also write <video>_result.json
```

The tool extracts audio, transcribes locally, summarizes (if a provider key is set), moves
the files to your destination, and posts a Slack notification (if configured).

### Watch mode (foreground)

```bash
transcribe watch ~/Movies   # Ctrl+C to stop
```

### Daemon mode (automatic)

See **[daemon.md](daemon.md)** for the background `launchd` agent.

## Output

Each meeting gets its own folder in `destination_directory`, named by date and meeting
title:

```
Meetings/
├── 2026-04-14 1000 Checkout latency and Q3 rollout/
│   ├── notes.md                 # summary, decisions, next steps, timestamped details
│   ├── notes.html               # the same notes as a standalone page
│   ├── notes.json               # machine-readable: notes plus every segment
│   ├── transcript.txt           # timestamped, grouped by speaker
│   ├── summary.txt              # the one-paragraph summary on its own
│   └── 2026-04-14 1000 ....mov  # this meeting's slice of the recording
└── Source recordings/
    └── 2026-08-25 09-34-17.mov  # the original, kept intact
```

When a recording contains only one meeting, the original recording is filed in that
meeting's folder and no clip is cut.

To keep the old behaviour — one transcript and one summary per file, in a folder named
after the video — use `--flat`, or set `meeting_mode: false` in the config.

## Upgrading

```bash
brew update
brew upgrade transcribe

# Restart the daemon if running
launchctl unload ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist
launchctl load ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist
```

## Uninstalling

```bash
# Stop and remove the daemon
launchctl unload ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist
rm ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist

# Uninstall the package
brew uninstall transcribe

# Optional: remove config and downloaded models
rm -rf ~/.transcribe
rm -rf ~/.whisper-models
```

## Troubleshooting

### Video not being processed

```bash
launchctl list | grep transcribe        # is the daemon running?
ps aux | grep "transcribe watch"
tail -50 ~/Library/Logs/transcribe.error.log
transcribe config | grep watch_directory # does it match the folder you use?
```

### "Model not found" / download issues

The model auto-downloads on first use. If the download was interrupted, remove the partial
file and retry, or pre-fetch manually:

```bash
ls -lh ~/.whisper-models/ggml-base.bin
rm -f ~/.whisper-models/ggml-base.bin.part
curl -L -o ~/.whisper-models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

### "Required tool not found"

```bash
brew install whisper-cpp ffmpeg
which ffmpeg whisper-cli
```

### Summaries not generated

- Confirm `llm_provider` matches a configured key (`anthropic_api_key` for `claude`,
  `openai_api_key` for `openai`).
- Without a key for the selected provider, summarization is skipped and only the transcript
  is produced.

### Google Drive link not working

```bash
gcloud auth application-default login
```

Or rely on the `file://` fallback for local access.

### Daemon not starting automatically

See [daemon.md](daemon.md#troubleshooting).

### Transcript is mostly "Thank you." or repeated filler

Voice Activity Detection is off. Recordings usually contain a floor of room tone rather
than digital silence, and fed that, Whisper hallucinates filler and can lock into a
repetition loop that ruins the rest of the file. Set `whisper_vad: true` (the default).

### Too many speakers on a long meeting

Voice embeddings drift over a long call, so an hour-plus meeting tends to split one person
into several clusters. The reliable fix is to tell it how many people were in the room,
which pins the cluster count instead of inferring it:

- Grant calendar access, so the attendee list is used automatically
  (`transcribe calendar-check`), or
- List the regulars in `known_participants`.

Failing that, raise `diarization_threshold` (0.8 → 0.9) to merge more aggressively.

### Speakers all show as "Speaker 1", "Speaker 2"

Diarization separated the voices but could not name them. Names are only applied when the
transcript supports them — a wrong name is worse than no name. To improve it:

- Grant calendar access so the attendee list is available (`transcribe calendar-check`).
- Or list the regulars in `known_participants` in your config.

### Speaker attribution missing entirely

`transcribe doctor` will say if `sherpa-onnx` or `numpy` is missing. Install with
`pip install 'transcribe[diarize]'`.

### One recording was split into the wrong number of meetings

- `--no-split` forces the whole recording to be treated as one meeting.
- Raise `meeting_gap_seconds` to make silence-based splitting less eager.
- Grant calendar access: real event boundaries beat inference.

### Diarization uses a lot of memory on very long meetings

Audio for a meeting is held in memory while voices are clustered, at roughly 4 MB per
minute. A three-hour single meeting needs about 800 MB. Splitting into real meetings keeps
this well below that; `diarization_enabled: false` turns it off entirely.

## Tips

1. Test with a short video before processing long recordings.
2. Monitor LLM usage/cost in your provider's dashboard.
3. The tool **moves** (not copies) files out of the watch directory — back up originals if
   needed.
4. Watch a specific folder (e.g. `~/Movies`), not your whole home directory.
5. Use `whisper_model: large-v3-turbo` for the best balance of quality and speed; use `base` if you need something faster and smaller.
6. Transcription takes roughly 1/4 of the video length on Apple Silicon.

## Support

- Issues: <https://github.com/CalebSargeant/transcribe/issues>
- Releases: <https://github.com/CalebSargeant/transcribe/releases>
