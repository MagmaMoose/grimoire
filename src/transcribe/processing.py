"""End-to-end pipeline: transcribe, split, attribute, summarize, file, notify."""

import json
import os
import shutil
from datetime import datetime
from pathlib import Path

from .calendars import events_for_recording
from .categorise import categorise_quietly
from .config import load_config
from .diarize import diarize_meeting
from .llm import (
    extract_action_items_with_openai,
    generate_title_description_with_openai,
    is_configured,
    summarize_with_openai,
)
from .locks import AlreadyClaimed, claim
from .media import cut_video, has_video_stream, probe_duration, recording_started_at
from .notes import (
    apply_corrections,
    generate_notes,
    naming_roster,
    notes_action_items,
    resolve_speaker_names,
)
from .render import render_html, render_markdown, render_transcript, safe_folder_name
from .segmentation import split_into_meetings
from .segments import Meeting, Segment, format_timestamp
from .slack import send_slack_notification
from .vocabulary import build_prompt
from .whisper import transcribe_video, transcribe_video_segments

# Exit statuses for a processing run, shared by the CLI and the macOS app. 75 is
# sysexits' EX_TEMPFAIL: nothing went wrong, someone else simply has the file.
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_BUSY = 75


def _llm_configured(config):
    """Return True if a key is set for the selected LLM provider."""
    return is_configured(config)


def move_files_to_destination(video_path, transcript_path, summary_path, config):
    """Move all files to a dedicated folder in the destination directory."""
    base_dest_dir = Path(config["destination_directory"])

    # Create a folder named after the video file (without extension)
    video_name = Path(video_path).stem
    video_folder = base_dest_dir / video_name
    video_folder.mkdir(parents=True, exist_ok=True)

    moved_files = {}

    # Move video
    video_dest = video_folder / Path(video_path).name
    shutil.move(video_path, video_dest)
    moved_files["video"] = str(video_dest)
    print(f"✓ Moved video to {video_dest}")

    # Move transcript
    if Path(transcript_path).exists():
        transcript_dest = video_folder / Path(transcript_path).name
        shutil.move(transcript_path, transcript_dest)
        moved_files["transcript"] = str(transcript_dest)
        print(f"✓ Moved transcript to {transcript_dest}")

    # Move summary if it exists
    if summary_path and Path(summary_path).exists():
        summary_dest = video_folder / Path(summary_path).name
        shutil.move(summary_path, summary_dest)
        moved_files["summary"] = str(summary_dest)
        print(f"✓ Moved summary to {summary_dest}")

    # Return the folder path as well
    moved_files["folder"] = str(video_folder)

    return moved_files


def _unique_folder(base_dir, name):
    """Return an unused folder path under ``base_dir``, suffixing on collision."""
    candidate = base_dir / name
    counter = 2
    while candidate.exists():
        candidate = base_dir / f"{name} ({counter})"
        counter += 1
    return candidate


def _folder_name_for(meeting, recording_start, notes):
    """Build the per-meeting folder name: an ISO date plus the meeting title."""
    title = (notes or {}).get("title") or meeting.title or f"Meeting {meeting.index}"
    if recording_start is not None:
        started = datetime.fromtimestamp(recording_start.timestamp() + meeting.start)
        prefix = started.strftime("%Y-%m-%d %H%M")
        return safe_folder_name(f"{prefix} {title}")
    return safe_folder_name(title)


def _write_meeting_outputs(
    meeting,
    notes,
    dest_dir,
    video_file,
    recording_start,
    config,
    split_video,
    write_transcript=True,
):
    """Write every artifact for one meeting into its own folder.

    ``write_transcript`` exists for the one caller that built the meeting *from*
    the transcript in this folder. Re-rendering it there replaces the original
    with a reconstruction: prose gains a fabricated speaker header and
    interpolated timestamps that read as measured, and raw whisper output loses
    its end times. The source is then gone.
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    written = {"folder": str(dest_dir)}
    source_name = Path(video_file).name

    notes_md = render_markdown(meeting, notes, recording_start, source_name)
    (dest_dir / "notes.md").write_text(notes_md, encoding="utf-8")
    written["notes_markdown"] = str(dest_dir / "notes.md")

    (dest_dir / "notes.html").write_text(
        render_html(meeting, notes, recording_start, source_name), encoding="utf-8"
    )
    written["notes_html"] = str(dest_dir / "notes.html")

    if write_transcript:
        (dest_dir / "transcript.txt").write_text(render_transcript(meeting), encoding="utf-8")
        written["transcript"] = str(dest_dir / "transcript.txt")

    if notes and notes.get("summary"):
        (dest_dir / "summary.txt").write_text(notes["summary"] + "\n", encoding="utf-8")
        written["summary"] = str(dest_dir / "summary.txt")

    payload = meeting.to_dict()
    payload["source_file"] = str(video_file)
    payload["recording_started_at"] = (
        recording_start.isoformat() if recording_start is not None else None
    )
    (dest_dir / "notes.json").write_text(
        json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    written["json"] = str(dest_dir / "notes.json")

    if split_video:
        # An audio-only source produces an audio clip; keeping the source's
        # container (.qta, say) would make a file nothing else opens.
        suffix = Path(video_file).suffix if has_video_stream(video_file) else ".m4a"
        clip = dest_dir / f"{safe_folder_name(dest_dir.name)}{suffix}"
        try:
            cut_video(video_file, str(clip), meeting.start, meeting.end)
            written["video"] = str(clip)
            print(f"  ✓ Video clip: {clip.name}")
        except Exception as e:
            print(f"  Warning: could not cut video clip ({type(e).__name__}: {e})")

    return written


def segments_from_text(text, duration=None):
    """Turn a plain transcript into segments spread across the recording.

    An externally supplied transcript (Voice Memos, for instance) carries no
    per-sentence timing. Splitting on sentences and distributing them evenly
    keeps the rest of the pipeline working, but the resulting timestamps are
    interpolated rather than measured, so they locate a passage roughly rather
    than exactly.
    """
    import re

    pieces = [piece.strip() for piece in re.split(r"(?<=[.!?])\s+", text or "") if piece.strip()]
    if not pieces:
        return []

    total = float(duration) if duration else 0.0
    if total <= 0:
        # Rough speaking pace, only used to give the segments an ordering.
        total = max(len(text.split()) / 150.0 * 60.0, len(pieces))

    span = total / len(pieces)
    return [
        Segment(start=index * span, end=(index + 1) * span, text=piece)
        for index, piece in enumerate(pieces)
    ]


def process_transcript(
    audio_file, transcript, config=None, title=None, recorded_at=None, duration=None
):
    """Run the notes pipeline over an already-transcribed recording.

    Used for sources that transcribe themselves, such as Voice Memos. Whisper is
    skipped; everything downstream (meeting notes, rendering, filing, Slack) is
    the same code path as a video.
    """
    config = config or load_config()
    audio_file = os.path.abspath(audio_file) if audio_file else None

    print(f"\n{'=' * 60}")
    name = Path(audio_file).name if audio_file else (title or "recording")
    print(f"Processing: {name}")
    print(f"{'=' * 60}\n")

    if not (transcript or "").strip():
        print("No transcript supplied; nothing to do.")
        return []

    if duration is None and audio_file:
        duration = probe_duration(audio_file) or None
    if recorded_at is None and audio_file:
        recorded_at = recording_started_at(audio_file)

    segments = segments_from_text(transcript, duration)
    print(f"✓ Using supplied transcript ({len(transcript.split()):,} words)")

    meeting = Meeting(index=1, start=0.0, end=segments[-1].end, segments=segments, title=title)

    if not is_configured(config):
        notes = None
        print("  Notes skipped (no LLM provider configured)")
    else:
        # Timestamps here are interpolated, so the model is told not to cite them.
        notes = generate_notes(
            meeting,
            config,
            extra_context=(
                "This transcript came from an external transcription service and has no "
                "reliable per-sentence timing. Do not cite timestamps."
            ),
        )
        if notes:
            meeting.title = notes.get("title") or meeting.title
            meeting.notes = notes
            print(f"  ✓ Notes: {meeting.title}")
        else:
            print("  ✗ Notes generation FAILED (see the warning above)")

    base_dest = Path(config.get("destination_directory") or Path(audio_file or ".").parent)
    folder = _unique_folder(base_dest, _folder_name_for(meeting, recorded_at, notes))
    written = _write_meeting_outputs(
        meeting, notes, folder, audio_file or name, recorded_at, config, split_video=False
    )
    if notes:
        categorise_quietly(folder, config)

    if audio_file and config.get("move_source_video", True):
        try:
            shutil.copy2(audio_file, Path(written["folder"]) / Path(audio_file).name)
            written["audio"] = str(Path(written["folder"]) / Path(audio_file).name)
            print(f"  ✓ Copied audio into {folder.name}")
        except Exception as e:
            print(f"  Warning: could not copy audio ({type(e).__name__}: {e})")

    action_items = notes_action_items(notes)
    if config.get("slack_webhook_url") or config.get("slack_bot_token"):
        send_slack_notification(
            name,
            written["folder"],
            meeting.title,
            (notes or {}).get("summary"),
            action_items,
            config,
        )

    print(f"\n{'=' * 60}")
    print(f"✓ Saved to {folder}")
    print(f"{'=' * 60}\n")
    return [
        {
            "title": meeting.title,
            "folder": written["folder"],
            "files": written,
            "action_items": action_items,
            "notes": notes,
        }
    ]


def process_recording(video_file, config=None, write_json=False, title=None):
    """Process a recording into one folder of notes per meeting it contains.

    ``title`` is a name the recording already carries, such as a Voice Memo the
    user labelled. It titles a single meeting that no calendar event names.

    Returns the list of per-meeting result dicts.
    """
    if config is None:
        config = load_config()

    video_file = os.path.abspath(video_file)
    print(f"\n{'=' * 60}")
    print(f"Processing: {Path(video_file).name}")
    print(f"{'=' * 60}\n")

    duration = probe_duration(video_file)
    recording_start = recording_started_at(video_file)
    if recording_start is not None:
        print(f"Recording started {recording_start:%Y-%m-%d %H:%M}, {duration / 60:.0f} minutes")

    # The calendar is read before transcribing rather than after: its title and
    # attendee names are the most specific vocabulary available for the decoder,
    # and priming it beats correcting the output afterwards.
    calendar_events = events_for_recording(recording_start, duration, config)
    if calendar_events:
        print(f"✓ Found {len(calendar_events)} calendar event(s) covering this recording")
        for event in calendar_events:
            print(f"    {event['start'][11:16]}  {event['title']}")

    prompt = build_prompt(config, calendar_events)
    if prompt:
        print(f"✓ Priming the decoder with {len(prompt.split(', '))} terms")

    segments, audio_path = transcribe_video_segments(
        video_file, {**config, "whisper_prompt": prompt}
    )
    print(
        f"✓ Transcribed {len(segments)} segments "
        f"({sum(len(s.text.split()) for s in segments):,} words)"
    )

    try:
        print("\n--- Identifying meetings ---")
        meetings = split_into_meetings(
            segments,
            config=config,
            calendar_events=calendar_events,
            recording_start=recording_start,
        )
        print(f"✓ Found {len(meetings)} meeting(s) in this recording")
        if title and len(meetings) == 1 and not meetings[0].title:
            meetings[0].title = title
        for meeting in meetings:
            label = meeting.title or "(untitled)"
            print(f"    {format_timestamp(meeting.start)}-{format_timestamp(meeting.end)}  {label}")

        results = []
        base_dest = Path(config.get("destination_directory") or Path(video_file).parent)
        split_video = bool(config.get("split_video", True)) and len(meetings) > 1

        for meeting in meetings:
            print(
                f"\n--- Meeting {meeting.index}/{len(meetings)}: {meeting.title or 'untitled'} ---"
            )

            if config.get("diarization_enabled", True):
                print("  Identifying speakers...")
                known = meeting.attendees or config.get("known_participants") or []
                # The attendee count is used as the cluster count. It reads like
                # an overestimate -- 11 invited where 8 speak -- but measured on
                # a 53-minute meeting it is the only thing that works: voice
                # embeddings drift over that length, so unconstrained clustering
                # split the room into 17 speakers and raising the threshold to
                # 0.95 only got it to 15. Pinning to 11 gave 8, and the silent
                # invitees fall out as micro-clusters on their own.
                if diarize_meeting(meeting, audio_path, config, num_speakers=len(known) or None):
                    print(f"  ✓ Separated {len(meeting.speakers())} voice(s)")
                    named = resolve_speaker_names(meeting, config, naming_roster(known, config))
                    if named:
                        print(
                            "  ✓ Named: "
                            + ", ".join(f"{label} → {name}" for label, name in named.items())
                        )
                    else:
                        # Silence here is indistinguishable from success at a
                        # glance, and the causes need different fixes.
                        print(f"  · No speakers named ({named.reason})")

            # Distinguish "no provider configured" from "the call failed": both
            # yield no notes, but only one of them is the user's doing.
            if not is_configured(config):
                notes = None
                print("  Notes skipped (no LLM provider configured)")
            else:
                notes = generate_notes(meeting, config)
                if notes:
                    meeting.title = notes.get("title") or meeting.title
                    meeting.notes = notes
                    print(f"  ✓ Notes: {meeting.title}")
                    steps = notes.get("next_steps") or []
                    if steps:
                        print(f"  ✓ {len(steps)} next step(s)")
                else:
                    print("  ✗ Notes generation FAILED (see the warning above)")

            if notes:
                repaired = apply_corrections(meeting, notes, when=recording_start)
                if repaired:
                    count = len(notes.get("corrections") or [])
                    print(
                        f"  ✓ Applied {count} transcript correction(s) across "
                        f"{repaired} segment(s), and learned them for next time"
                    )

            folder = _unique_folder(base_dest, _folder_name_for(meeting, recording_start, notes))
            written = _write_meeting_outputs(
                meeting, notes, folder, video_file, recording_start, config, split_video
            )
            print(f"  ✓ Saved to {folder}")
            if notes:
                categorise_quietly(folder, config)

            action_items = notes_action_items(notes)
            if config.get("slack_webhook_url") or config.get("slack_bot_token"):
                send_slack_notification(
                    Path(video_file).name,
                    written["folder"],
                    meeting.title,
                    (notes or {}).get("summary"),
                    action_items,
                    config,
                )

            results.append(
                {
                    "title": meeting.title,
                    "folder": written["folder"],
                    "files": written,
                    "action_items": action_items,
                    "notes": notes,
                }
            )

        # The source recording is only moved once every meeting has been written,
        # so a failure part-way through never loses the original.
        if config.get("destination_directory") and config.get("move_source_video", True):
            _archive_source(video_file, base_dest, results, split_video)
        else:
            # Said out loud: a recording left in the watch folder otherwise looks
            # exactly like one the pipeline forgot to file.
            print("\n· Left the source recording where it was (move_source_video is off)")

        print(f"\n{'=' * 60}")
        print(f"✓ Processing complete — {len(results)} meeting(s)")
        print(f"{'=' * 60}\n")
        return results

    finally:
        if os.path.exists(audio_path):
            os.unlink(audio_path)


def _archive_source(video_file, base_dest, results, was_split):
    """Move the source recording next to its notes, or into an archive folder.

    Returns the new path, or None when the move failed.
    """
    try:
        if len(results) == 1 and not was_split:
            # One meeting: the recording belongs in that meeting's folder.
            folder = Path(results[0]["folder"])
        else:
            folder = base_dest / SOURCE_ARCHIVE
            folder.mkdir(parents=True, exist_ok=True)
        # A rename onto an existing path replaces it without a word, and the
        # archive folder collects every split recording, so a reused name (OBS
        # restarts its counter) would silently destroy an earlier recording.
        destination = _unique_file(folder, Path(video_file).name)
        shutil.move(video_file, destination)
        print(f"\n✓ Moved source recording to {destination}")
        return destination
    except Exception as e:
        print(f"Warning: could not move source recording ({type(e).__name__}: {e})")
        return None


# Where a recording that became several meetings is kept, since no single
# meeting folder owns it.
SOURCE_ARCHIVE = "Source recordings"


def _unique_file(folder, name):
    """A path for ``name`` in ``folder`` that does not exist yet."""
    candidate = Path(folder) / name
    stem, suffix = Path(name).stem, Path(name).suffix
    counter = 2
    while candidate.exists():
        candidate = Path(folder) / f"{stem} ({counter}){suffix}"
        counter += 1
    return candidate


def process_video_file(video_file, config=None, write_json=False, title=None):
    """Process a video file.

    Runs the meeting-aware pipeline by default. Setting ``meeting_mode: false``
    in config selects the original flat behaviour: one transcript, one summary,
    one folder named after the video file.

    Returns ``EXIT_OK``, ``EXIT_FAILED``, or ``EXIT_BUSY`` when another process
    already has the file.
    """
    if config is None:
        config = load_config()

    # Returned rather than swallowed: the app runs this as a subprocess and read
    # a crashed run's exit status 0 as success, so a failure was reported as
    # "finished" and the recording sat in the queue marked as done.
    try:
        with claim(video_file):
            if not config.get("meeting_mode", True):
                return _process_video_file_flat(video_file, config, write_json)
            try:
                process_recording(video_file, config, write_json=write_json, title=title)
            except Exception as e:
                print(f"\nError processing {video_file}: {e}")
                import traceback

                traceback.print_exc()
                return EXIT_FAILED
            return EXIT_OK
    except AlreadyClaimed as e:
        print(f"Skipping: {e} by another transcribe process.")
        return EXIT_BUSY


def _process_video_file_flat(video_file, config, write_json=False):
    """The original single-transcript pipeline, kept for ``meeting_mode: false``."""
    print(f"\n{'=' * 60}")
    print(f"Processing: {Path(video_file).name}")
    print(f"{'=' * 60}\n")

    try:
        # Transcribe
        transcript = transcribe_video(video_file, config)
        print("\n--- Transcription Complete ---")

        # Save transcript
        transcript_file = video_file.rsplit(".", 1)[0] + "_transcript.txt"
        with open(transcript_file, "w") as f:
            f.write(transcript)
        print(f"✓ Transcript saved to: {transcript_file}")

        # Generate title and description with the configured LLM provider
        title = None
        description = None
        summary = None
        summary_file = None

        if _llm_configured(config):
            print("\n--- Generating Summary ---")
            summary = summarize_with_openai(transcript, config)
            if summary:
                summary_file = video_file.rsplit(".", 1)[0] + "_summary.txt"
                with open(summary_file, "w") as f:
                    f.write(summary)
                print(f"✓ Summary saved to: {summary_file}")

            print("\n--- Generating Title & Description for Slack ---")
            title, description = generate_title_description_with_openai(transcript, config)
            if title:
                print(f"✓ Title: {title}")
            if description:
                print(f"✓ Description: {description}")

            print("\n--- Extracting Action Items ---")
            action_items = extract_action_items_with_openai(transcript, config)
            if action_items:
                print(f"✓ Found {len(action_items)} action item(s)")
                for i, item in enumerate(action_items, 1):
                    print(f"  {i}. {item}")
            else:
                print("✓ No specific action items identified")
        else:
            action_items = []

        # Build the JSON result payload (written after the move below so it
        # lands in the same destination folder as the transcript/summary).
        result_payload = None
        if write_json:
            result_payload = {
                "title": title,
                "description": description,
                "transcript": transcript,
                "summary": summary,
                "action_items": action_items,
                "source_file": video_file,
            }

        # Move files to destination
        if config.get("destination_directory"):
            print("\n--- Moving Files ---")
            moved_files = move_files_to_destination(
                video_file, transcript_file, summary_file, config
            )

            # Write the JSON result into the same destination folder as the
            # moved transcript/summary, so it is not orphaned at the source.
            if result_payload is not None:
                result_name = Path(video_file).stem + "_result.json"
                result_file = str(Path(moved_files["folder"]) / result_name)
                with open(result_file, "w") as f:
                    json.dump(result_payload, f, indent=2, ensure_ascii=False)
                print(f"✓ JSON result saved to: {result_file}")

            # Send Slack notification
            if config.get("slack_webhook_url") or config.get("slack_bot_token"):
                print("\n--- Sending Notification ---")
                send_slack_notification(
                    Path(video_file).name,
                    moved_files.get("folder"),
                    title,
                    description,
                    action_items,
                    config,
                )
        elif result_payload is not None:
            # No destination configured: fall back to writing the JSON next to
            # the (un-moved) source video so the output is not lost.
            result_file = video_file.rsplit(".", 1)[0] + "_result.json"
            with open(result_file, "w") as f:
                json.dump(result_payload, f, indent=2, ensure_ascii=False)
            print(f"✓ JSON result saved to: {result_file}")

        print(f"\n{'=' * 60}")
        print("✓ Processing complete!")
        print(f"{'=' * 60}\n")
        return EXIT_OK

    except Exception as e:
        print(f"\nError processing {video_file}: {e}")
        import traceback

        traceback.print_exc()
        return EXIT_FAILED
