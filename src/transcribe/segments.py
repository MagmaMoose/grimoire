"""Shared data model for timestamped transcript segments and meetings."""

from dataclasses import dataclass, field


def format_timestamp(seconds):
    """Format seconds as ``HH:MM:SS`` -- the form used in the notes."""
    seconds = max(int(seconds), 0)
    return f"{seconds // 3600:02d}:{(seconds % 3600) // 60:02d}:{seconds % 60:02d}"


@dataclass
class Segment:
    """One timestamped chunk of transcript, optionally attributed to a speaker.

    Times are seconds from the start of the source recording, so a segment stays
    meaningful after a recording is split into several meetings.
    """

    start: float
    end: float
    text: str
    speaker: str | None = None

    @property
    def duration(self):
        return max(self.end - self.start, 0.0)

    def to_dict(self):
        return {
            "start": round(self.start, 3),
            "end": round(self.end, 3),
            "timestamp": format_timestamp(self.start),
            "text": self.text,
            "speaker": self.speaker,
        }


@dataclass
class Meeting:
    """A contiguous stretch of a recording treated as a single meeting."""

    index: int
    start: float
    end: float
    segments: list[Segment] = field(default_factory=list)
    title: str | None = None
    attendees: list[str] = field(default_factory=list)
    calendar_event: dict | None = None
    notes: dict | None = None
    # False when the timestamps were spread evenly across untimed text rather
    # than measured. The notes prompt must not invite citing those.
    timings_are_measured: bool = True

    @property
    def duration(self):
        return max(self.end - self.start, 0.0)

    def transcript_text(self, with_speakers=True, with_timestamps=True):
        """Render this meeting's segments as text for an LLM prompt.

        Timestamps are relative to the start of the recording so they line up
        with the source video, which is what the notes cite.
        """
        lines = []
        for segment in self.segments:
            prefix = ""
            if with_timestamps:
                prefix += f"[{format_timestamp(segment.start)}] "
            if with_speakers and segment.speaker:
                prefix += f"{segment.speaker}: "
            lines.append(f"{prefix}{segment.text}")
        return "\n".join(lines)

    def speakers(self):
        """Distinct speaker labels in this meeting, ordered by talk time."""
        totals = {}
        for segment in self.segments:
            if segment.speaker:
                totals[segment.speaker] = totals.get(segment.speaker, 0.0) + segment.duration
        return [name for name, _ in sorted(totals.items(), key=lambda kv: -kv[1])]

    def to_dict(self):
        return {
            "index": self.index,
            "title": self.title,
            "start": round(self.start, 3),
            "end": round(self.end, 3),
            "start_timestamp": format_timestamp(self.start),
            "end_timestamp": format_timestamp(self.end),
            "duration_seconds": round(self.duration, 3),
            "attendees": self.attendees,
            "speakers": self.speakers(),
            "calendar_event": self.calendar_event,
            "notes": self.notes,
            "segments": [segment.to_dict() for segment in self.segments],
        }
