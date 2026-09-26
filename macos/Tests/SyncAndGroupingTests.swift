import Foundation
import Testing

@testable import Transcribe

// Pure logic behind Reminders sync, grouping, the queue and auto-record. Nothing
// here needs Reminders, OBS or a real library.

@Suite("Owners")
struct OwnerTests {
    /// "Speaker 2" says which voice, not whose job it is. A filter offering
    /// Speaker 1, 2 and 3 offered nothing a person could act on.
    @Test(
        "anonymous owners are nobody",
        arguments: ["Unassigned", "Speaker 1", "SPEAKER_00", "speaker 12", "Speaker A", "Unknown speaker", "", "  "])
    func anonymous(owner: String) {
        #expect(Owner.named(owner) == nil)
    }

    @Test("real owners are kept", arguments: ["Priya", "Sam Okoro", "Speakerman", "The platform team"])
    func named(owner: String) {
        #expect(Owner.named(owner) == owner)
    }

    @Test("the user is found by first or full name")
    func user() {
        #expect(Owner.isUser("Caleb", named: "Caleb Sargeant"))
        #expect(Owner.isUser("caleb sargeant", named: "Caleb Sargeant"))
        #expect(Owner.isUser("Caleb and Priya", named: "Caleb"))
        #expect(!Owner.isUser("Priya", named: "Caleb Sargeant"))
        #expect(!Owner.isUser("Speaker 1", named: "Caleb"))
        #expect(!Owner.isUser("Caleb", named: ""))
    }
}

@Suite("Completion keys")
struct CompletionKeyTests {
    private let action = IndexedMeeting.Action(owner: "Sam", title: "Ship", detail: "it")

    /// A directory URL may end in a slash or not depending on how it was made.
    @Test("a trailing slash is the same meeting")
    func trailingSlash() {
        #expect(
            Completions.key(meeting: URL(filePath: "/m/Standup/"), action: action)
                == Completions.key(meeting: URL(filePath: "/m/Standup"), action: action))
    }

    /// `transcribe actions done` writes the same file.
    @Test("the key is the one the command line builds")
    func matchesTheCLI() {
        #expect(Completions.key(meeting: URL(filePath: "/m/Standup"), action: action) == "/m/Standup|SamShipit")
    }

    @Test("keys written with a slash are brought into line")
    func normalise() {
        #expect(Completions.normalise("/m/Standup/|SamShipit") == "/m/Standup|SamShipit")
        #expect(Completions.normalise("/|x") == "/|x")
        #expect(Completions.normalise("no separator") == "no separator")
    }
}

@Suite("Reminders merge")
struct ReminderMergeTests {
    @Test("both sides agreeing needs nothing")
    func agreed() {
        #expect(ReminderMerge.resolve(app: true, reminder: true, last: false) == .agreed(true))
        #expect(ReminderMerge.resolve(app: false, reminder: false, last: false) == .agreed(false))
    }

    @Test("a tick in the app goes to Reminders")
    func pushTick() {
        #expect(ReminderMerge.resolve(app: true, reminder: false, last: false) == .push(true))
    }

    @Test("an untick in the app goes to Reminders")
    func pushUntick() {
        #expect(ReminderMerge.resolve(app: false, reminder: true, last: true) == .push(false))
    }

    @Test("a tick in Reminders comes back")
    func pullTick() {
        #expect(ReminderMerge.resolve(app: false, reminder: true, last: false) == .pull(true))
    }

    @Test("an untick in Reminders comes back")
    func pullUntick() {
        #expect(ReminderMerge.resolve(app: true, reminder: false, last: true) == .pull(false))
    }
}

@Suite("Reminders ledger")
struct ReminderLedgerTests {
    /// `Hasher` is seeded per launch, which would give every reminder a new ref
    /// each time the app started and add everything again.
    @Test("refs are stable, short and distinct")
    func refs() {
        let ref = ReminderLedger.ref(for: "/m/a|x")
        #expect(ref == ReminderLedger.ref(for: "/m/a|x"))
        #expect(ref != ReminderLedger.ref(for: "/m/b|x"))
        #expect(ref.count == 16)
        // FNV-1a's offset basis: nothing hashed, nothing changed.
        #expect(ReminderLedger.ref(for: "") == "cbf29ce484222325")
    }

    @Test("the mark in a reminder's notes is found again")
    func marker() {
        let action = IndexedMeeting.Action(owner: "Sam", title: "Ship", detail: "Before Friday")
        let notes = ReminderContent.notes(
            for: action, meetingTitle: "Standup", meetingDate: nil, ref: "abc123")
        #expect(notes.hasPrefix("Before Friday"))
        #expect(notes.contains("From: Standup"))
        #expect(ReminderLedger.ref(inNotes: notes) == "abc123")
        #expect(ReminderLedger.ref(inNotes: "just some notes") == nil)
        #expect(ReminderLedger.ref(inNotes: nil) == nil)
    }

    @Test("the ledger round trips, and survives missing keys")
    func roundTrip() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var ledger = ReminderLedger()
        ledger.list = "list"
        ledger.items["k"] = ReminderLedger.Entry(reminder: "r", ref: "f", done: true)
        ledger.dismissed = ["gone"]
        try ledger.save(to: url)
        #expect(ReminderLedger.load(from: url) == ledger)

        try Data(#"{"items":{}}"#.utf8).write(to: url)
        let partial = ReminderLedger.load(from: url)
        #expect(partial.dismissed.isEmpty && partial.list == nil)
        #expect(ReminderLedger.load(from: URL(filePath: "/nonexistent/ledger.json")) == ReminderLedger())
    }

    @Test("a reminder names the owner only when it is someone else")
    func titles() {
        let theirs = IndexedMeeting.Action(owner: "Priya", title: "Send the quote", detail: "")
        let mine = IndexedMeeting.Action(owner: "Caleb", title: "Book the room", detail: "")
        let nobody = IndexedMeeting.Action(owner: "Speaker 2", title: "Tidy up", detail: "")
        #expect(ReminderContent.title(for: theirs, userName: "Caleb") == "Send the quote (Priya)")
        #expect(ReminderContent.title(for: mine, userName: "Caleb") == "Book the room")
        #expect(ReminderContent.title(for: nobody, userName: "Caleb") == "Tidy up")
    }

    @Test("mine means yours and unassigned, and everything without a name")
    func scope() {
        #expect(ReminderScope.mine.includes(owner: "Caleb", userName: "Caleb"))
        #expect(ReminderScope.mine.includes(owner: "Unassigned", userName: "Caleb"))
        #expect(!ReminderScope.mine.includes(owner: "Priya", userName: "Caleb"))
        #expect(ReminderScope.mine.includes(owner: "Priya", userName: ""))
        #expect(ReminderScope.all.includes(owner: "Priya", userName: "Caleb"))
        #expect(ReminderScope.from("ALL") == .all)
        #expect(ReminderScope.from("nonsense") == .mine)
    }

    /// "Added 1 reminder(s) to Reminders" after sending ten read as one of ten,
    /// in a list called Reminders.
    @Test("the summary says how many, and where")
    func summary() {
        #expect(RemindersSync.summary(added: 0, pushed: 0, pulled: 0, list: "Meetings") == nil)
        #expect(
            RemindersSync.summary(added: 1, pushed: 0, pulled: 0, list: "Meetings")
                == "Added 1 action item to “Meetings” in Reminders.")
        #expect(
            RemindersSync.summary(added: 3, pushed: 0, pulled: 2, list: "M")
                == "Added 3 action items to “M” in Reminders, picked up 2 changes made in Reminders.")
        #expect(
            RemindersSync.summary(added: 0, pushed: 1, pulled: 0, list: "M") == "Updated 1 in Reminders.")
    }
}

@Suite("Library grouping")
struct GroupingTests {
    private func folder(_ name: String, _ date: String?) -> MeetingFolder {
        MeetingFolder(
            id: URL(filePath: "/m/\(name)"), name: name,
            date: date.flatMap { MeetingLibrary.folderDate(from: $0) })
    }

    private var folders: [MeetingFolder] {
        [
            folder("c", "2026-09-20 0900"),
            folder("b", "2026-09-10 0900"),
            folder("a", "2026-08-01 0900"),
            folder("undated", nil),
        ]
    }

    @Test("by month keeps the date order and puts undated last")
    func byMonth() {
        let groups = LibraryGrouping.groups(
            folders, by: .month, categories: { _ in [] }, field: { _, _ in nil })
        #expect(groups.map(\.value.count) == [2, 1, 1])
        #expect(groups.last?.key == "Undated")
    }

    @Test("by category uses the first one, most recent group first")
    func byCategory() {
        let categories: [String: [String]] = [
            "/m/c": ["Hiring"], "/m/b": ["Standup", "Hiring"], "/m/a": ["Hiring"],
        ]
        let groups = LibraryGrouping.groups(
            folders, by: .category,
            categories: { categories[$0.path(percentEncoded: false)] ?? [] },
            field: { _, _ in nil })
        #expect(groups.map(\.key) == ["Hiring", "Standup", "Uncategorised"])
        #expect(groups[0].value.map(\.name) == ["c", "a"])
    }

    @Test("by a field, with meetings that have none last")
    func byField() {
        let companies = ["/m/b": "Acme", "/m/a": "Globex"]
        let groups = LibraryGrouping.groups(
            folders, by: .field("Company"), categories: { _ in [] },
            field: { name, url in name == "Company" ? companies[url.path(percentEncoded: false)] : nil })
        #expect(groups.map(\.key) == ["Acme", "Globex", "No Company"])
        #expect(groups.last?.value.map(\.name) == ["c", "undated"])
    }

    @Test("the stored choice round trips")
    func ids() {
        for grouping in [LibraryGrouping.month, .category, .field("Company")] {
            #expect(LibraryGrouping(id: grouping.id) == grouping)
        }
        #expect(LibraryGrouping(id: "nonsense") == .month)
        #expect(LibraryGrouping(id: "field:") == .month)
    }
}

@Suite("Tags with fields")
struct TagFieldTests {
    private func temporaryFolder() -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "transcribe-fields-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("fields round trip beside the categories")
    func roundTrip() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Tags(names: ["Standup"], fields: ["Company": "Acme"]).save(in: folder)
        let loaded = Tags.load(in: folder)
        #expect(loaded.names == ["Standup"])
        #expect(loaded.fields == ["Company": "Acme"])
    }

    /// Written by the command line before fields existed.
    @Test("a file with only names still reads")
    func namesOnly() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"names": ["Hiring"]}"#.utf8).write(to: folder.appending(path: Tags.filename))
        #expect(Tags.load(in: folder) == Tags(names: ["Hiring"]))
    }

    @Test("a file with only fields is kept, and an empty one removed")
    func fieldsOnly() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: Tags.filename)
        try Tags(fields: ["Project": "Website"]).save(in: folder)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try Tags().save(in: folder)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// A file nobody grouped stays byte for byte what the command line wrote.
    @Test("no fields means no fields key")
    func noEmptyKey() throws {
        let data = try JSONEncoder().encode(Tags(names: ["Hiring"]))
        #expect(!String(decoding: data, as: UTF8.self).contains("fields"))
    }
}

@Suite("Placeholder names")
struct PlaceholderTests {
    @Test(
        "fallback names are placeholders",
        arguments: [
            "2026-09-26 1400 Meeting 1", "2026-09-26 1400", "2026-09-26 1400 Untitled meeting",
            "New Recording 3", "2026-08-27 0905 Voice Memo 2026-08-27 09 05",
        ])
    func placeholders(name: String) {
        #expect(MeetingFolder(id: URL(filePath: "/m/\(name)"), name: name, date: nil).hasPlaceholderName)
    }

    @Test(
        "chosen names are not",
        arguments: [
            "2026-09-26 1400 Board prep", "Standup-20241120_095537-Meeting Recording", "Meeting with Acme",
        ])
    func realNames(name: String) {
        #expect(!MeetingFolder(id: URL(filePath: "/m/\(name)"), name: name, date: nil).hasPlaceholderName)
    }
}

@Suite("Pipeline output")
struct PipelineOutputTests {
    @Test("a renamed folder is followed")
    func rename() {
        let target = URL(filePath: "/m/2026-09-26 1400 Meeting 1")
        let output = "--- x ---\n✓ Renamed folder to: /m/2026-09-26 1400 Budget review\n✓ Notes: Budget review"
        #expect(Pipeline.renames(in: output, target: target) == [target: URL(filePath: "/m/2026-09-26 1400 Budget review")])
    }

    @Test("no rename, or no target, is nothing")
    func none() {
        #expect(Pipeline.renames(in: "✓ Notes: x", target: URL(filePath: "/m/a")).isEmpty)
        #expect(Pipeline.renames(in: "✓ Renamed folder to: /m/b", target: nil).isEmpty)
    }

    @Test("the reason for a failure is the telling line, not the whole log")
    func reason() {
        let output = "Processing: a.mov\nError processing a.mov: boom\n  File \"x\"\nRuntimeError: boom\n"
        #expect(Automation.reason(from: output) == "RuntimeError: boom")
        #expect(Automation.reason(from: "✗ No LLM provider configured.") == "No LLM provider configured.")
        #expect(Automation.reason(from: "") == "see the log")
    }
}

@Suite("Recordings settling")
struct SettlingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func recording(size: Int64, writtenAgo: Double) -> PendingRecording {
        PendingRecording(
            url: URL(filePath: "/w/a.mov"), size: size,
            modified: now.addingTimeInterval(-writtenAgo), processedInto: [])
    }

    /// OBS grows the file for the whole meeting. Processing it early files
    /// half a meeting.
    @Test("a file is only picked up once it has stopped changing")
    func settled() {
        let quiet = recording(size: 100, writtenAgo: 60)
        #expect(Automation.isSettled(quiet, previous: (100, quiet.modified), now: now))
        #expect(!Automation.isSettled(quiet, previous: nil, now: now))
        #expect(!Automation.isSettled(quiet, previous: (90, quiet.modified), now: now))

        let justWritten = recording(size: 100, writtenAgo: 5)
        #expect(!Automation.isSettled(justWritten, previous: (100, justWritten.modified), now: now))

        let empty = recording(size: 0, writtenAgo: 600)
        #expect(!Automation.isSettled(empty, previous: (0, empty.modified), now: now))
    }

    /// The watch folder defaults to ~/Movies. Switching automatic processing on
    /// must not transcribe every video already in it.
    @Test("only recordings that arrive afterwards are processed on their own")
    func onlyNewOnes() {
        let switchedOn = now.addingTimeInterval(-3600)
        #expect(Automation.isNew(recording(size: 1, writtenAgo: 60), since: switchedOn))
        #expect(!Automation.isNew(recording(size: 1, writtenAgo: 7200), since: switchedOn))
        let undated = PendingRecording(
            url: URL(filePath: "/w/b.mov"), size: 1, modified: nil, processedInto: [])
        #expect(!Automation.isNew(undated, since: switchedOn))
    }
}

@Suite("OBS")
struct OBSTests {
    /// The worked example from the obs-websocket protocol documentation.
    @Test("the authentication string matches the protocol's example")
    func authentication() {
        #expect(
            OBS.authentication(
                password: "supersecretpassword",
                salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
                challenge: "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY=")
                == "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
    }

    @Test("nothing listening is an error, not a hang")
    func unreachable() async {
        let started = Date()
        await #expect(throws: (any Error).self) {
            // Port 1 on this machine: nothing listens there, so the refusal is immediate.
            let closed = OBS.Connection(host: "127.0.0.1", port: 1, password: "")  // DevSkim: ignore DS162092 - a deliberately closed local port
            _ = try await OBS.send("GetVersion", to: closed, timeout: 3)
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

@MainActor
@Suite("Auto-record switches")
struct AutoRecordSwitchTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []
        func append(_ value: Bool) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [Bool] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func monitor(_ extra: [String: String] = [:]) -> (RecordingMonitor, Calls) {
        var values = [
            ConfigKey.startAfter: "45", ConfigKey.stopAfter: "120", ConfigKey.minFreeGB: "0",
        ]
        for (key, value) in extra { values[key] = value }
        let m = RecordingMonitor(settings: Settings(config: Configuration(values: values)))
        let calls = Calls()
        m.control = { start in calls.append(start); return true }
        return (m, calls)
    }

    @Test("switched off, a meeting never starts a recording")
    func off() async {
        let (m, calls) = monitor([ConfigKey.autoRecord: "false"])
        m.setPresenceForTesting(Presence.State(microphone: true, camera: true))
        await m.decide(now: t0)
        await m.decide(now: t0.addingTimeInterval(100))
        #expect(calls.values.isEmpty)
        #expect(m.status == .idle)
    }

    @Test("a skipped meeting is left alone until it ends")
    func skipped() async {
        let (m, calls) = monitor()
        m.setPresenceForTesting(Presence.State(microphone: true, camera: true))
        await m.decide(now: t0)
        #expect(m.status == .detected)
        m.skipCurrentMeeting()
        await m.decide(now: t0.addingTimeInterval(100))
        #expect(calls.values.isEmpty)
        #expect(m.status == .skipped)

        m.setPresenceForTesting(Presence.State(microphone: false))
        await m.decide(now: t0.addingTimeInterval(110))
        #expect(m.status == .idle)

        m.setPresenceForTesting(Presence.State(microphone: true, camera: true))
        await m.decide(now: t0.addingTimeInterval(120))
        await m.decide(now: t0.addingTimeInterval(170))
        #expect(calls.values == [true])
    }

    @Test("the recorder's own reason for failing is what is shown")
    func controlError() async {
        let (m, _) = monitor()
        m.control = { _ in
            m.controlError = "OBS is not installed."
            return false
        }
        await m.setRecording(true, now: t0)
        #expect(m.lastError == "OBS is not installed.")
    }
}
