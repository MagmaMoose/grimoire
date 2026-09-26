# Transcribe for macOS

A native SwiftUI app over the meeting folders the pipeline writes.

## What it does

* **Meetings** grouped by month, by category, or by a field of your own such as
  Company or Project, and search across every transcript rather than just
  titles. A result opens the meeting and seeks the recording to the line that
  matched.
* **Notes, transcript and recording** side by side. Any timestamp seeks the
  media. Audio-only recordings get a compact transport, not a black rectangle.
* **Action items** from every meeting in one list, by owner, kept in step with a
  Reminders list.
* **Recording queue** showing what is in the watch folder and whether it became
  a meeting, with new recordings processed as they arrive.
* **Auto-record**, driving OBS itself, with the state and any error shown in the
  main window as well as the menu bar.
* **Every setting** the CLI reads, editable.

## Without being asked

Each of these has a switch under Settings > General, and runs with the app open
or only in the menu bar:

* **New recordings** in the watch folder are processed once they have stopped
  growing for 30 seconds. Nothing starts while a recording is under way.
* **Missing notes** are written for meetings from the last two weeks that have a
  transcript and none, usually because the provider failed on the first run. A
  meeting still called "Meeting 1" is renamed after its notes' title.
* **New Voice Memos** are imported every ten minutes, each once, from a copy, so
  the memo stays in Voice Memos. This needs Full Disk Access for Transcribe.

Runs go through one queue, one at a time. A click on Write Notes goes to the
front of it rather than stopping what is running.

## Generating notes

Two paths, and the default is the cheap one:

* **From the transcript** — parses the transcript the folder already has and
  writes notes from it. Nothing is re-transcribed. Three formats are handled:
  this pipeline's speaker-grouped form, raw whisper's `[00:00.000 --> …]`
  ranges, and plain prose with no timings (which interpolates, because there is
  nothing else to go on).
* **Re-transcribe** — runs the whole pipeline again, which takes about as long
  as the meeting.

Most of an existing library predates structured notes, and for the oldest
meetings the audio is gone entirely, so the transcript is the only route.

## Apple Notes and Reminders

Reminders is the task list; the app does not try to be one. Once connected,
action items from the last 30 days go into a Reminders list ("Meetings" unless
you pick another), yours and unassigned ones by default. Each carries the
meeting it came from and a link to its folder.

`~/.transcribe/reminders.json` records which reminder stands for which action,
and whether it was done when the two sides last agreed. That is what makes it a
sync rather than an export: nothing is added twice, and whichever side changed
since then wins, so a tick in Reminders ticks the action here and the reverse.
Deleting a reminder counts as done and it is not added again. A small ref in
each reminder's notes finds it again if the ledger is lost.

Notes has no public API, so a note is filed by driving the Notes app with
AppleScript. The note body is written to a file that the script reads; it is
never interpolated into script source, because a transcript containing a quote
would be a syntax error and one containing script would be worse. macOS asks for
automation permission the first time.

## Build and run

```sh
cd macos && xcodegen generate && open Transcribe.xcodeproj
```

```sh
xcodebuild -project macos/Transcribe.xcodeproj -scheme Transcribe -configuration Release build
```

Tests need no simulator:

```sh
xcodebuild -project macos/Transcribe.xcodeproj -scheme Transcribe -destination 'platform=macOS' test
```

The project file is generated. After adding, renaming or deleting a Swift file,
run `xcodegen generate` and commit the result; a new file on disk is otherwise
absent from the target even though a `swiftc` sweep over the tree passes.

## How it talks to the pipeline

`notes.json`, which the CLI writes into every meeting folder, is the whole
interface. The app reads it and never imports anything Python. Folders without
one still appear, showing whatever transcript and summary they hold, because
they are most of an existing library.

Everything that does work (writing notes, categorising, processing a queued
recording, importing Voice Memos) shells out to the `transcribe` CLI rather than
reimplementing it, so there is one implementation and one set of settings behind
both. The CLI is looked up in the usual Homebrew locations. It exits non-zero
when a run fails, 75 when another `transcribe` process already has the file,
and 77 when it needs a permission, and the app reports each differently.

OBS is the exception. The app speaks obs-websocket itself, because the Homebrew
build of the CLI does not bundle the websocket client and every automatic start
through it failed.

Settings live in `~/.transcribe/config.yaml`, the same file the CLI reads. Edits
are line-surgical, so comments and anything the app does not model survive.

## Folder access

Meeting folders usually live in iCloud Drive, which macOS treats as a protected
location. A denied read there does not fail: the process blocks inside `open(2)`
and never returns. The app gives the first listing four seconds and then offers
the open panel, because *picking* the folder is what grants access.

The grant is tied to the app's code signature. Ad-hoc signing produces a new one
on every build, so each rebuild loses per-folder grants. Granting Transcribe
**Full Disk Access** once avoids that; a Developer ID would fix it properly.

## Deployment target

macOS 14. The version in the typecheck sweep has to match, or the gate stops
enforcing what it exists for:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun --sdk macosx swiftc -typecheck -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  $(find macos/Transcribe -name '*.swift')
```

## Signing and distribution

Ad-hoc, which is fine on the machine that built it. `Transcribe.entitlements`
carries the automation entitlement that the hardened runtime requires for the
Notes export, so the remaining work to hand this to someone else is a Developer
ID, `ENABLE_HARDENED_RUNTIME`, and notarisation.

## Auto-record

A meeting is the microphone plus one corroborating signal: the camera, or a
calendar event happening now. Detection is native, which is what puts the
microphone, camera and calendar grants on Transcribe rather than on whichever
terminal launched the CLI. Calendar access is asked for from Settings > Recording
or the menu bar; without it, a meeting joined with the camera off is never seen.

On macOS 14.2 and later the app also asks CoreAudio which processes hold the
microphone, and ignores OBS. OBS keeps the microphone open for as long as it
runs, which otherwise kept every recording going and made an idle OBS during
any calendar event look like a meeting.

Each start sets OBS's recording folder to the watch folder, so the file lands
where the queue picks it up.
