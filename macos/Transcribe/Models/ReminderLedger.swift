import Foundation

/// What has been sent to Reminders, and the state each item was in last time.
///
/// Reminders is the task list; this app does not try to be one. The ledger is
/// what makes that a sync rather than an export: it remembers which reminder
/// stands for which action, so nothing is added twice, and it remembers whether
/// each was done the last time both sides agreed, so a later difference can be
/// traced to the side that changed.
///
/// Stored in `~/.transcribe/reminders.json`, beside the completions file it is
/// reconciled against.
struct ReminderLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// `calendarItemIdentifier`. Can change on a full resync, so the ref in
        /// the reminder's notes is the fallback.
        var reminder: String
        var ref: String
        /// Whether it was done when the two sides last agreed.
        var done: Bool
    }

    /// The list the reminders were put in.
    var list: String?
    /// Keyed by the completion key, the same identity `Completions` uses.
    var items: [String: Entry] = [:]
    /// Actions whose reminder the user deleted. Deleting one is an answer, and
    /// recreating it on the next sync would ignore that answer.
    var dismissed: Set<String> = []

    init() {}

    // Decoded field by field so a file from a later version, or a hand edit
    // that drops a key, still loads instead of resetting everything and
    // sending every action to Reminders again.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = try container.decodeIfPresent(String.self, forKey: .list)
        items = try container.decodeIfPresent([String: Entry].self, forKey: .items) ?? [:]
        dismissed = try container.decodeIfPresent(Set<String>.self, forKey: .dismissed) ?? []
    }

    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".transcribe/reminders.json")

    static func load(from url: URL = url) -> ReminderLedger {
        guard let data = try? Data(contentsOf: url),
            let ledger = try? JSONDecoder().decode(ReminderLedger.self, from: data)
        else { return ReminderLedger() }
        return ledger
    }

    func save(to url: URL = url) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - The mark on a reminder

    /// A short, stable name for an action, written into its reminder's notes.
    ///
    /// FNV-1a rather than `Hasher`, which is seeded per launch and would give
    /// every reminder a new ref each time the app started.
    static func ref(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    static let markerPrefix = "Transcribe ref: "

    /// The ref written in a reminder's notes, if it is one of ours.
    static func ref(inNotes notes: String?) -> String? {
        guard let notes else { return nil }
        for line in notes.split(whereSeparator: \.isNewline).reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(markerPrefix) {
                let ref = text.dropFirst(markerPrefix.count).trimmingCharacters(in: .whitespaces)
                return ref.isEmpty ? nil : ref
            }
        }
        return nil
    }
}

/// Which side of a completion changed since the two last agreed.
enum ReminderMerge {
    enum Outcome: Equatable {
        /// Both sides already say this.
        case agreed(Bool)
        /// The app changed: Reminders should say this.
        case push(Bool)
        /// Reminders changed: the app should say this.
        case pull(Bool)
    }

    /// With one boolean per side, a disagreement always has exactly one side
    /// that still matches the last agreed state, so there is never a conflict
    /// to break: whichever side moved away from it is the one that changed.
    static func resolve(app: Bool, reminder: Bool, last: Bool) -> Outcome {
        if app == reminder { return .agreed(app) }
        return app == last ? .pull(reminder) : .push(app)
    }
}

/// What goes into a reminder.
enum ReminderContent {
    /// The owner is added when it is someone else, since a reminder that reads
    /// "Send the quote" is ambiguous about whose job that is.
    static func title(for action: IndexedMeeting.Action, userName: String) -> String {
        guard let owner = action.assignedOwner, !Owner.isUser(owner, named: userName) else {
            return action.title
        }
        return "\(action.title) (\(owner))"
    }

    /// The meeting it came from, and the mark that makes it findable again.
    static func notes(
        for action: IndexedMeeting.Action, meetingTitle: String, meetingDate: Date?, ref: String
    ) -> String {
        var lines: [String] = []
        if !action.detail.isEmpty {
            lines.append(action.detail)
            lines.append("")
        }
        var from = "From: \(meetingTitle)"
        if let meetingDate {
            from += ", " + meetingDate.formatted(date: .abbreviated, time: .shortened)
        }
        lines.append(from)
        lines.append(ReminderLedger.markerPrefix + ref)
        return lines.joined(separator: "\n")
    }
}

/// Which action items belong in Reminders.
enum ReminderScope: String, CaseIterable, Sendable {
    /// Yours, and the ones nobody has claimed yet. Someone else's action is
    /// theirs to track, not an item on your list.
    case mine
    case all

    static func from(_ raw: String) -> ReminderScope {
        ReminderScope(rawValue: raw.lowercased()) ?? .mine
    }

    /// Without a name there is no telling which are yours, so everything goes.
    func includes(owner: String, userName: String) -> Bool {
        switch self {
        case .all:
            return true
        case .mine:
            let me = userName.trimmingCharacters(in: .whitespaces)
            guard !me.isEmpty, Owner.named(owner) != nil else { return true }
            return Owner.isUser(owner, named: me)
        }
    }
}
