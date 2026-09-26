"""Meeting notes generation: summary, decisions, next steps, and details.

The output mirrors the structure of an assistant-generated meeting summary:
a short overview, themed sections, decisions split by whether the room actually
agreed, owner-tagged next steps, and a timestamped narrative of what was said.

Everything is produced in one schema-constrained call per meeting so the parts
stay consistent with each other, and every detail line carries a timestamp so a
claim can be checked against the recording.
"""

import re

from .llm import complete_json, is_configured
from .segments import format_timestamp

# Roughly four characters per token; used only to decide when to condense a very
# long transcript rather than to bill anything.
CHARS_PER_TOKEN = 4
DEFAULT_TRANSCRIPT_TOKEN_BUDGET = 120_000

# Naming speakers does not need the whole meeting. Introductions cluster at the
# start and sign-offs at the end, and the per-speaker excerpts carry the rest of
# the signal, so a much smaller slice answers the question just as well for a
# fraction of the latency and cost.
# Introductions land in the first minute or two of a call.
SPEAKER_CONTEXT_SECONDS = 120
SPEAKER_TOKEN_BUDGET = 4_000
# Excerpts are there to characterise a voice, not to be read closely.
SPEAKER_EXCERPT_TURNS = 3
SPEAKER_EXCERPT_CHARS = 140

# Only ask about voices with enough airtime to be worth naming. Clustering on a
# long meeting produces a tail of near-silent fragments, and asking a model to
# place every one of them turns a lookup into a combinatorial puzzle it will
# happily think about for minutes.
MAX_SPEAKERS_TO_NAME = 6
MIN_SPEAKER_SECONDS_TO_NAME = 60.0

SPEAKER_SCHEMA = {
    "type": "object",
    "properties": {
        "speakers": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {
                        "type": "string",
                        "description": "The anonymous label being identified, e.g. 'Speaker 1'.",
                    },
                    "name": {
                        "type": "string",
                        "description": "The person's real name, or an empty string if the "
                        "transcript gives no reliable evidence for one.",
                    },
                    "confidence": {
                        "type": "string",
                        "enum": ["high", "medium", "low"],
                        "description": "How well the transcript supports this name.",
                    },
                },
                "required": ["label", "name", "confidence"],
            },
        }
    },
    "required": ["speakers"],
}

NOTES_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {
            "type": "string",
            "description": "A specific 3-8 word title naming what this meeting was about. "
            "Not generic: 'Camera subnet routing fixes', not 'Team meeting'.",
        },
        "summary": {
            "type": "string",
            "description": "One or two sentences covering what the meeting achieved.",
        },
        "sections": {
            "type": "array",
            "description": "The two to five main themes of the meeting.",
            "items": {
                "type": "object",
                "properties": {
                    "heading": {"type": "string", "description": "A short theme heading."},
                    "body": {
                        "type": "string",
                        "description": "Two or three sentences on this theme, stating what "
                        "was concluded rather than narrating the conversation.",
                    },
                },
                "required": ["heading", "body"],
            },
        },
        "decisions": {
            "type": "array",
            "description": "Decisions reached or explicitly left open. Empty if none.",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Short name for the decision."},
                    "detail": {
                        "type": "string",
                        "description": "What was decided, in one or two sentences.",
                    },
                    "status": {
                        "type": "string",
                        "enum": ["aligned", "needs_further_discussion"],
                        "description": "'aligned' when the group agreed; "
                        "'needs_further_discussion' when it was raised but left unresolved.",
                    },
                },
                "required": ["title", "detail", "status"],
            },
        },
        "next_steps": {
            "type": "array",
            "description": "Concrete follow-up actions. Empty if the meeting produced none.",
            "items": {
                "type": "object",
                "properties": {
                    "owner": {
                        "type": "string",
                        "description": "Who owns this, by name. Use 'Unassigned' only when "
                        "the transcript genuinely names no owner.",
                    },
                    "title": {
                        "type": "string",
                        "description": "A short imperative name for the action, e.g. "
                        "'Update Terraform docs'.",
                    },
                    "detail": {
                        "type": "string",
                        "description": "One or two sentences on what doing this involves.",
                    },
                },
                "required": ["owner", "title", "detail"],
            },
        },
        "corrections": {
            "type": "array",
            "description": "Proper nouns and technical terms the transcript clearly got "
            "wrong, which you were able to infer from context. Only include ones you are "
            "confident about. Empty if the transcript looks clean.",
            "items": {
                "type": "object",
                "properties": {
                    "heard": {
                        "type": "string",
                        "description": "The wrong text exactly as it appears in the "
                        "transcript, e.g. 'humanitis'.",
                    },
                    "correct": {
                        "type": "string",
                        "description": "What was actually said, e.g. 'Kubernetes'.",
                    },
                },
                "required": ["heard", "correct"],
            },
        },
        "details": {
            "type": "array",
            "description": "A chronological walkthrough of the meeting, one entry per topic "
            "discussed. This is the longest section: aim for 8-20 entries on a "
            "substantial meeting.",
            "items": {
                "type": "object",
                "properties": {
                    "heading": {"type": "string", "description": "What this passage covered."},
                    "body": {
                        "type": "string",
                        "description": "Two to four sentences. Attribute statements to the "
                        "named speaker where the transcript supports it.",
                    },
                    "timestamps": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "One or two HH:MM:SS timestamps taken verbatim from "
                        "the transcript markers for this passage.",
                    },
                },
                "required": ["heading", "body"],
            },
        },
    },
    "required": ["title", "summary", "sections", "details"],
}


def _condense(text, token_budget):
    """Trim a transcript that exceeds the budget, keeping the start and the end.

    Meetings open with context and close with commitments, so when something has
    to go it should come from the middle.
    """
    limit = token_budget * CHARS_PER_TOKEN
    if len(text) <= limit:
        return text
    head = int(limit * 0.6)
    tail = limit - head
    return (
        text[:head] + "\n\n[... middle of the transcript omitted for length ...]\n\n" + text[-tail:]
    )


class SpeakerNames(dict):
    """The names that were resolved, and why there were not more of them.

    Naming comes back empty for four different reasons -- no provider, nobody
    spoke long enough, the call failed, or the transcript simply does not say
    who anyone is -- and only the last is a normal outcome. The log has to tell
    them apart, but every caller wants the mapping. Subclassing dict carries the
    explanation without making callers unpack a tuple to reach the names.
    """

    def __init__(self, mapping=None, reason=""):
        super().__init__(mapping or {})
        self.reason = reason


def _naming_context(meeting, known_participants=None, window=SPEAKER_CONTEXT_SECONDS):
    """Return the passages that actually identify who is talking.

    Two things name a speaker: the opening, where people greet and introduce
    themselves, and any line where someone says a participant's name out loud.
    Everything else is subject matter.

    The second half only works when ``known_participants`` is supplied. Without
    a roster the opening is all there is, which on a long meeting is far too
    little to place six voices -- the model reads two minutes of hellos and
    returns low confidence for everyone.

    Sending more than that measurably backfires. Given ten minutes of
    surrounding transcript, deepseek-v4-pro spent its entire completion budget
    reasoning and returned nothing; given only these passages it answers in
    seconds.
    """
    segments = meeting.segments
    if not segments:
        return ""

    first_names = {name.split()[0].lower() for name in (known_participants or []) if name.split()}

    picked, seen = [], set()
    for segment in segments:
        in_opening = segment.start <= meeting.start + window
        lowered = segment.text.lower()
        names_someone = any(first_name in lowered for first_name in first_names)
        if (in_opening or names_someone) and id(segment) not in seen:
            seen.add(id(segment))
            picked.append(segment)

    text = "\n".join(
        f"[{format_timestamp(seg.start)}] {seg.speaker or '?'}: {seg.text}" for seg in picked
    )
    return _condense(text, SPEAKER_TOKEN_BUDGET)


def naming_roster(known, config):
    """The names a voice may be given: the attendees, plus the user.

    The user is in every recording they make, and is the one person a calendar
    invite most often leaves off (the organiser is not always listed). Adding
    them to the roster is what lets their own voice be named rather than stay
    "Speaker 1" in their own notes.
    """
    roster = list(known or [])
    me = (config.get("user_name") or "").strip()
    if me and not any(me.lower() == str(name).strip().lower() for name in roster):
        roster.append(me)
    return roster


def resolve_speaker_names(meeting, config, known_participants=None):
    """Replace anonymous ``Speaker N`` labels with real names where evidence exists.

    Diarization can tell voices apart but not who they belong to. Names come from
    the conversation itself -- greetings, direct address, handovers -- optionally
    narrowed by a known attendee list from the calendar or config.

    Labels stay anonymous when the evidence is weak, which is the right outcome:
    a wrong name in the notes is worse than no name.
    """
    if not is_configured(config):
        return SpeakerNames(reason="no LLM provider configured")

    # meeting.speakers() is ordered by talk time, so this keeps the people who
    # actually held the floor and drops the fragment tail.
    talk_times = {}
    for segment in meeting.segments:
        if segment.speaker:
            talk_times[segment.speaker] = talk_times.get(segment.speaker, 0.0) + segment.duration
    labels = [
        label
        for label in meeting.speakers()
        if talk_times.get(label, 0.0) >= MIN_SPEAKER_SECONDS_TO_NAME
    ][:MAX_SPEAKERS_TO_NAME]
    if not labels:
        return SpeakerNames(reason=f"no voice spoke for {MIN_SPEAKER_SECONDS_TO_NAME:.0f}s or more")

    samples = []
    for label in labels:
        turns = [seg for seg in meeting.segments if seg.speaker == label]
        turns.sort(key=lambda seg: -seg.duration)
        excerpt = " / ".join(
            seg.text[:SPEAKER_EXCERPT_CHARS] for seg in turns[:SPEAKER_EXCERPT_TURNS]
        )
        samples.append(f"{label} (speaks for {talk_times[label] / 60:.1f} min): {excerpt}")

    roster = ""
    if known_participants:
        roster = (
            "\n\nThese people were invited to the meeting. Prefer these names, but only "
            "assign one when the transcript actually supports it:\n"
            + "\n".join(f"- {name}" for name in known_participants)
        )

    system = (
        "You identify who is speaking in a meeting transcript. Voices have been "
        "separated into anonymous labels; your job is to name them using evidence in "
        "the conversation: self-introductions, people addressing each other by name, "
        "and handovers ('over to you, Sam'). Return an empty name when the evidence is "
        "weak. A wrong name is worse than no name."
    )
    user = (
        "Speakers to identify:\n"
        + "\n\n".join(samples)
        + roster
        + "\n\nPassages where people are named:\n"
        + _naming_context(meeting, known_participants)
    )

    result = complete_json(
        config,
        system,
        user,
        SPEAKER_SCHEMA,
        max_tokens=int(config.get("speaker_max_tokens", 16000)),
    )
    if result is None:
        return SpeakerNames(reason="the naming call failed")

    mapping = {}
    for entry in result.get("speakers", []):
        label = entry.get("label")
        name = (entry.get("name") or "").strip()
        if label and name and entry.get("confidence") in ("high", "medium"):
            mapping[label] = name

    for segment in meeting.segments:
        if segment.speaker in mapping:
            segment.speaker = mapping[segment.speaker]
    if not mapping:
        return SpeakerNames(
            reason=f"no confident match for any of the {len(labels)} voice(s) put forward"
        )
    return SpeakerNames(mapping, reason=f"{len(mapping)} of {len(labels)} voice(s) named")


def generate_notes(meeting, config, extra_context=None):
    """Produce structured notes for one meeting.

    Returns the notes dict, or None when no LLM is configured or the call fails.
    """
    if not is_configured(config):
        return None

    budget = int(config.get("transcript_token_budget", DEFAULT_TRANSCRIPT_TOKEN_BUDGET))
    transcript = _condense(meeting.transcript_text(), budget)

    context_lines = [
        f"Meeting runs from {format_timestamp(meeting.start)} to "
        f"{format_timestamp(meeting.end)} in the recording "
        f"({meeting.duration / 60:.0f} minutes)."
    ]
    if meeting.calendar_event:
        event = meeting.calendar_event
        context_lines.append(f"Calendar title: {event.get('title')}")
        if event.get("attendees"):
            context_lines.append("Invited: " + ", ".join(event["attendees"]))
    elif meeting.attendees:
        context_lines.append("Known participants: " + ", ".join(meeting.attendees))
    speakers = meeting.speakers()
    if speakers:
        context_lines.append("Speakers detected: " + ", ".join(speakers))
    if extra_context:
        context_lines.append(extra_context)

    system = (
        "You write meeting notes that a participant can read instead of rewatching "
        "the recording, and that someone who missed it can act on.\n\n"
        "Rules:\n"
        "- Only state what the transcript supports. Never invent names, numbers, "
        "decisions, or owners.\n"
        "- Attribute statements to named speakers where the transcript makes the "
        "speaker clear; otherwise write neutrally.\n"
        "- Timestamps must be copied verbatim from the [HH:MM:SS] markers in the "
        "transcript. Never invent or interpolate one.\n"
        "- Write plainly and specifically. Prefer the concrete detail ('three camera "
        "subnets') over the vague gesture ('some network changes').\n"
        "- The transcript comes from automatic speech recognition, so proper nouns and "
        "technical terms may be misspelled. Infer the intended term where it is "
        "obvious from context, and list those in 'corrections' so the transcript can "
        "be repaired and the term recognised next time.\n"
        "- Leave decisions and next steps empty rather than padding them with "
        "discussion points that nobody committed to."
    )
    user = (
        "Context:\n"
        + "\n".join(f"- {line}" for line in context_lines)
        + "\n\nTranscript:\n"
        + transcript
    )

    return complete_json(
        config,
        system,
        user,
        NOTES_SCHEMA,
        max_tokens=int(config.get("notes_max_tokens", 8000)),
        temperature=float(config.get("notes_temperature", 0.2)),
    )


def notes_action_items(notes):
    """Flatten a notes dict's next steps into ``[Owner] Title: detail`` strings.

    Used for the Slack message and the legacy ``action_items`` JSON field.
    """
    if not notes:
        return []
    items = []
    for step in notes.get("next_steps") or []:
        owner = (step.get("owner") or "").strip()
        title = (step.get("title") or "").strip()
        detail = (step.get("detail") or "").strip()
        prefix = f"[{owner}] " if owner and owner.lower() != "unassigned" else ""
        items.append(f"{prefix}{title}: {detail}" if detail else f"{prefix}{title}")
    return items


def apply_corrections(meeting, notes, glossary_path=None, when=None):
    """Repair the transcript using the corrections the notes call reported.

    The model reads the whole transcript to write the notes, so it already works
    out that "humanitis" was Kubernetes. Surfacing that lets two things happen:
    the stored transcript stops being wrong, and the corrected term is recorded
    so the decoder is primed with it next time rather than mishearing it again.

    Returns the number of segments changed.
    """
    from .vocabulary import record_terms

    corrections = [
        (entry.get("heard") or "", entry.get("correct") or "")
        for entry in (notes or {}).get("corrections") or []
    ]
    corrections = [
        (heard.strip(), correct.strip())
        for heard, correct in corrections
        if heard.strip() and correct.strip() and heard.strip().lower() != correct.strip().lower()
    ]
    if not corrections:
        return 0

    changed = 0
    for segment in meeting.segments:
        original = segment.text
        text = original
        for heard, correct in corrections:
            # Word-boundary, case-insensitive: a mis-hearing rarely matches case.
            safe = correct.replace("\\", "\\\\")
            text = re.sub(rf"\b{re.escape(heard)}\b", safe, text, flags=re.IGNORECASE)
        if text != original:
            segment.text = text
            changed += 1

    record_terms(
        {correct: 1 for _, correct in corrections},
        path=glossary_path,
        when=(when.isoformat() if hasattr(when, "isoformat") else when),
    )
    return changed
