# Background daemon

Run Transcribe as a macOS `launchd` agent so videos dropped into your watch directory are
processed automatically, with the service starting on login and restarting if it crashes.

> macOS only.

## Setup

```bash
# Generate the launchd plist (uses watch_directory from your config)
transcribe setup-daemon

# Start the daemon
launchctl load ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist

# Confirm it is running
launchctl list | grep transcribe
# e.g. 12345   0   com.calebsargeant.transcribe
```

`setup-daemon` writes `~/Library/LaunchAgents/com.calebsargeant.transcribe.plist`. The agent
runs `transcribe watch <watch_directory>` with `RunAtLoad` and `KeepAlive` enabled, and sets
`PYTHONUNBUFFERED=1` so logs stream live.

Once loaded, any video dropped into the watch directory is transcribed, split into its
constituent meetings, attributed to speakers, summarized into notes, filed one folder per
meeting, and announced in Slack automatically.

The watcher waits for the file to stop growing before it starts. A recorder creates its
file when the meeting *begins* and keeps writing until it ends, so the creation event can
arrive hours before the recording is actually complete.

### Calendar permission

Grant calendar access **before** loading the daemon. macOS shows its permission prompt in
a UI session, which a launchd agent does not have, so the daemon can never trigger it:

```bash
transcribe calendar-check
```

Without this, the daemon still works — it just falls back to inferring meeting titles from
the transcript instead of reading them from your calendar.

## Logs

```bash
# Standard output and error logs
tail -f ~/Library/Logs/transcribe.log
tail -f ~/Library/Logs/transcribe.error.log

# Both at once
tail -f ~/Library/Logs/transcribe.log ~/Library/Logs/transcribe.error.log
```

On startup you should see lines like:

```
Watching directory: /Users/you/Movies
Video extensions: .mov, .mp4, .avi, .mkv, .m4v
```

and, when a file appears:

```
Detected new file: test.mp4
Waiting for file to finish writing...
```

followed by transcription progress.

## Stop / restart

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist

# Restart
launchctl unload ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist
launchctl load ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist
```

## Testing

Drop a small file into the watch directory and watch the logs:

```bash
# Watch the logs in one terminal
tail -f ~/Library/Logs/transcribe.log ~/Library/Logs/transcribe.error.log

# In another terminal, create a tiny test video
ffmpeg -f lavfi -i testsrc=duration=5:size=320x240:rate=30 \
       -f lavfi -i sine=frequency=1000:duration=5 \
       -pix_fmt yuv420p ~/Movies/test.mp4
```

In the destination folder you should then see:

- `transcript.txt` — full transcription with timestamps
- `notes.md`, `notes.html`, `notes.json` — structured meeting notes (if LLM key is configured)
- `summary.txt` — one-paragraph summary (if LLM key is configured)
- a Slack notification (if configured)

## Troubleshooting

```bash
# Is it running?
launchctl list | grep transcribe
ps aux | grep "transcribe watch"

# Recent logs / errors
tail -n 50 ~/Library/Logs/transcribe.log
tail -n 50 ~/Library/Logs/transcribe.error.log

# Verify the plist exists and is valid
ls -la ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist
plutil -lint ~/Library/LaunchAgents/com.calebsargeant.transcribe.plist

# Run the watcher in the foreground for live debugging
transcribe watch ~/Movies
```

If the daemon does not pick up files, confirm the watched directory matches your config:

```bash
transcribe config | grep watch_directory
```
