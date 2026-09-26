import Foundation

/// The `notes.json` the Python pipeline writes into each meeting folder.
///
/// This is the whole interface between the two halves of the project: the CLI
/// writes it, the app reads it, and neither needs to know anything else about
/// the other. Keys are the pipeline's own snake_case spelling, declared
/// explicitly rather than via `.convertFromSnakeCase`, so a key that moves
/// breaks here rather than silently decoding to nil.
struct MeetingRecord: Codable, Sendable {
    let index: Int
    let title: String?
    let start: Double
    let end: Double
    let durationSeconds: Double
    let attendees: [String]
    let speakers: [String]
    let calendarEvent: CalendarEvent?
    let notes: Notes?
    let segments: [Segment]
    let sourceFile: String?
    let recordingStartedAt: Date?

    enum CodingKeys: String, CodingKey {
        case index, title, start, end, attendees, speakers, notes, segments
        case durationSeconds = "duration_seconds"
        case calendarEvent = "calendar_event"
        case sourceFile = "source_file"
        case recordingStartedAt = "recording_started_at"
    }

    struct CalendarEvent: Codable, Sendable {
        let title: String?
        let start: Date?
        let end: Date?
        let attendees: [String]
        let location: String?
        let calendar: String?
    }

    struct Notes: Codable, Sendable {
        let title: String?
        let summary: String?
        let sections: [Section]
        let decisions: [Decision]
        let nextSteps: [NextStep]
        let corrections: [Correction]
        let details: [Detail]

        enum CodingKeys: String, CodingKey {
            case title, summary, sections, decisions, corrections, details
            case nextSteps = "next_steps"
        }

        // Every array is optional in practice: a meeting that reached no
        // decisions omits the key rather than writing an empty list, and the
        // older files predate several of these entirely.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
            decisions = try container.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
            nextSteps = try container.decodeIfPresent([NextStep].self, forKey: .nextSteps) ?? []
            corrections = try container.decodeIfPresent([Correction].self, forKey: .corrections) ?? []
            details = try container.decodeIfPresent([Detail].self, forKey: .details) ?? []
        }
    }

    struct Section: Codable, Sendable, Identifiable {
        var id: String { heading + body }
        let heading: String
        let body: String
    }

    struct Decision: Codable, Sendable, Identifiable {
        var id: String { title + detail }
        let title: String
        let detail: String
        let status: Status

        /// The pipeline writes exactly these two, but an unrecognised value
        /// must not fail the whole file, so decoding falls back rather than
        /// throwing.
        enum Status: String, Codable, Sendable {
            case aligned
            case needsFurtherDiscussion = "needs_further_discussion"

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Status(rawValue: raw) ?? .needsFurtherDiscussion
            }
        }
    }

    struct NextStep: Codable, Sendable, Identifiable {
        var id: String { owner + title + detail }
        let owner: String
        let title: String
        let detail: String

        /// An owner the pipeline could not determine is written as
        /// "Unassigned"; the view should show that as absent, not as a person.
        var assignedOwner: String? { Owner.named(owner) }
    }

    struct Correction: Codable, Sendable, Identifiable {
        var id: String { heard + correct }
        let heard: String
        let correct: String
    }

    struct Detail: Codable, Sendable, Identifiable {
        var id: String { heading + body }
        let heading: String
        let body: String
        let timestamps: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            heading = try container.decode(String.self, forKey: .heading)
            body = try container.decode(String.self, forKey: .body)
            timestamps = try container.decodeIfPresent([String].self, forKey: .timestamps) ?? []
        }
    }

    /// One line of transcript. `speaker` is null wherever diarization declined
    /// to attribute the line, which is common at the edges of a turn.
    struct Segment: Codable, Sendable, Identifiable {
        var id: Double { start }
        let start: Double
        let end: Double
        let timestamp: String
        let text: String
        let speaker: String?
    }
}

extension MeetingRecord {
    /// The title to show, preferring the LLM's over the calendar's own.
    var displayTitle: String {
        notes?.title ?? title ?? calendarEvent?.title ?? "Untitled meeting"
    }

    /// Speakers that actually say something, in the order they appear. The
    /// `speakers` key lists every cluster including the silent tail.
    var speakingParticipants: [String] {
        var seen = Set<String>()
        return segments.compactMap { segment in
            guard let speaker = segment.speaker, seen.insert(speaker).inserted else { return nil }
            return speaker
        }
    }

    /// How far to shift a timestamp before seeking the file in this folder.
    ///
    /// Every timestamp in the file is measured from the start of the *whole
    /// recording*. The pipeline only cuts a clip when a recording held more
    /// than one meeting; a single-meeting recording is moved in whole. So the
    /// same timestamp means different things depending on which of those two
    /// the folder ended up with, and subtracting unconditionally seeks a
    /// single-meeting recording to the wrong place.
    ///
    /// The source file's own name identifies the uncut case.
    func clipOffset(forMedia media: URL?) -> Double {
        guard let media, let sourceFile else { return start }
        let sourceName = URL(filePath: sourceFile).lastPathComponent
        return media.lastPathComponent == sourceName ? 0 : start
    }
}

/// The pipeline writes local wall-clock time with no offset
/// (`2026-08-27T11:05:56`), which `.iso8601` rejects outright because it
/// requires a timezone. Parsing it as local time is correct: the recording
/// happened on this Mac, in this timezone.
enum PipelineDate {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Fractional seconds have appeared in some files; drop them rather
            // than failing the whole record over sub-second precision nobody
            // reads.
            let trimmed = String(raw.prefix(19))
            guard let date = formatter.date(from: trimmed) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unparseable date \(raw)")
                )
            }
            return date
        }
        return decoder
    }
}


/// Who owns an action item.
///
/// The pipeline writes "Unassigned" when it could not tell, and both the record
/// and the index needed to turn that back into "nobody". It was written out
/// twice, verbatim.
enum Owner {
    static func named(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Unassigned") != .orderedSame
        else { return nil }
        return trimmed
    }
}
