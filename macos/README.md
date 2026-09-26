# Transcribe for macOS

A native SwiftUI app over the meeting folders the pipeline writes.

## What it does

* **Meetings** grouped by month, with categories, and search across every
  transcript rather than just titles. A result opens the meeting and seeks the
  recording to the line that matched.
* **Notes, transcript and recording** side by side. Any timestamp seeks the
  media. Audio-only recordings get a compact transport, not a black rectangle.
* **Action items** from every meeting in one list, by owner, with a done state,
  exportable to Reminders.
* **Recording queue** showing what is in the watch folder and whether it became
  a meeting.
* **Menu bar** item showing whether a meeting is detected, with a manual
  override.
* **Every setting** the CLI reads, editable.

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

Reminders uses EventKit, which is a real API with a real permission: action
items become reminders carrying the meeting title and a path back to its folder.

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

Everything that *does* work — writing notes, categorising, processing a queued
recording, starting and stopping OBS — shells out to the `transcribe` CLI rather
than reimplementing it, so there is one implementation and one set of settings
behind both. The CLI is looked up in the usual Homebrew locations.

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

## Not built yet

Automatic recording. The menu bar shows what the detector sees and can start or
stop OBS by hand, but the start/stop *timing* still lives in `transcribe
autorecord`. Detection itself is native here, which is what puts the microphone
and camera grants on Transcribe rather than on whichever terminal launched the
CLI.
