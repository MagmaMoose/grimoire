import AppKit
import EventKit
import Foundation

/// The work nobody should have to ask for.
///
/// A recording that lands in the watch folder gets processed. A meeting filed
/// without notes gets them. A new Voice Memo becomes a meeting. Action items
/// stay in step with Reminders. Each of these used to wait for a click: the
/// queue had a Process button per file and nothing else, so a recording sat
/// there until someone noticed it.
///
/// Lives at app level, not in a window, so it keeps working with every window
/// closed and only the menu bar item left.
@MainActor
@Observable
final class Automation {
    /// Why a recording that is waiting was not processed, for the queue.
    private(set) var failures: [URL: String] = [:]
    /// Set when a Voice Memos import needed Full Disk Access and did not have
    /// it. Asking again every few minutes would only repeat the refusal.
    private(set) var voiceMemosBlocked: String?

    private var attempted: Set<URL> = []
    private var notesAttempted: Set<URL> = []
    /// Recordings older than this are left for the user. The watch folder
    /// defaults to ~/Movies, and switching this on must not transcribe every
    /// video already in it; only what arrives from then on is processed.
    private(set) var processingSince: Date = .distantFuture
    private var lastSeen: [URL: Snapshot] = [:]
    private var lastVoiceMemos: Date?
    private var lastReminders: Date?
    private var lastRefresh: Date?
    private var refreshing = false
    private var refreshAgain = false
    private var timer: Task<Void, Never>?
    private var remindersTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private struct Snapshot: Equatable {
        let size: Int64
        let modified: Date?
    }

    /// How long a recording must sit unchanged before it counts as finished.
    /// OBS grows the file for the whole meeting, and processing half of one
    /// files half a meeting.
    nonisolated static let settleSeconds: Double = 30
    static let tickSeconds: Double = 30
    /// Meetings older than this never get notes written on their own, so a
    /// library of old transcripts does not quietly become a large bill.
    static let notesWindowDays: Double = 14
    static let voiceMemosInterval: Double = 10 * 60
    static let remindersInterval: Double = 10 * 60

    let settings: Settings
    let library: MeetingLibrary
    let tags: TagIndex
    let index: MeetingIndex
    let queue: WatchQueue
    let pipeline: Pipeline
    let completions: Completions
    let reminders: RemindersSync
    let monitor: RecordingMonitor

    init(
        settings: Settings, library: MeetingLibrary, tags: TagIndex, index: MeetingIndex,
        queue: WatchQueue, pipeline: Pipeline, completions: Completions,
        reminders: RemindersSync, monitor: RecordingMonitor
    ) {
        self.settings = settings
        self.library = library
        self.tags = tags
        self.index = index
        self.queue = queue
        self.pipeline = pipeline
        self.completions = completions
        self.reminders = reminders
        self.monitor = monitor
    }

    /// Where the start of automatic processing is remembered across launches.
    static let processingSinceKey = "autoProcessSince"

    func start() {
        guard timer == nil else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.processingSinceKey) == nil {
            defaults.set(Date(), forKey: Self.processingSinceKey)
        }
        processingSince = defaults.object(forKey: Self.processingSinceKey) as? Date ?? Date()

        pipeline.onCompletion = { [weak self] completion in self?.handle(completion) }
        completions.onChange = { [weak self] key, done in self?.reminders.push(key: key, done: done) }

        // Reminders changes arrive as this notification, whichever app made
        // them, including this one; a sync that finds nothing to do is cheap.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRemindersSync(after: 2) }
            })
        // The command line may have ticked something off while the app was in
        // the background.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.completions.reload()
                    self?.scheduleRemindersSync(after: 1)
                }
            })

        timer = Task { [weak self] in
            // Give the window's own first load a head start.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(Automation.tickSeconds))
            }
        }
    }

    /// Read the library, its tags, the search index and the watch folder.
    ///
    /// Coalesced: a refresh asked for while one runs becomes one more pass
    /// afterwards, not a second concurrent read of every folder.
    func refresh() async {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        repeat {
            refreshAgain = false
            await library.load(root: settings.folder(ConfigKey.destination))
            await tags.load(folders: library.folders)
            index.build(folders: library.folders)
            await queue.load(watch: settings.folder(ConfigKey.watch), library: library.folders)
        } while refreshAgain
        refreshing = false
        lastRefresh = Date()
        scheduleRemindersSync(after: 1)
    }

    /// One pass: look at the watch folder, then start whatever is due.
    func tick() async {
        if library.phase == .idle { await refresh() }
        await queue.load(watch: settings.folder(ConfigKey.watch), library: library.folders)
        processNewRecordings()
        writeMissingNotes()
        importVoiceMemos()
        if lastReminders.map({ Date().timeIntervalSince($0) >= Self.remindersInterval }) ?? true {
            scheduleRemindersSync(after: 0)
        }
    }

    // MARK: - Recordings

    private func processNewRecordings(now: Date = Date()) {
        var seen: [URL: Snapshot] = [:]
        let enabled = settings.config.bool(ConfigKey.autoProcess, default: true)
        for recording in queue.pending {
            let snapshot = Snapshot(size: recording.size, modified: recording.modified)
            seen[recording.url] = snapshot
            let previous = lastSeen[recording.url].map { (size: $0.size, modified: $0.modified) }
            guard enabled, Self.isNew(recording, since: processingSince),
                Self.isSettled(recording, previous: previous, now: now)
            else { continue }
            guard !attempted.contains(recording.url), pipeline.job(for: recording.url) == nil
            else { continue }
            // Transcribing is heavy enough to make a live recording drop frames.
            guard monitor.status != .recording else { continue }
            attempted.insert(recording.url)
            pipeline.process(recording.url, automatic: true)
        }
        lastSeen = seen
    }

    /// True when a recording looks finished: the same size and date as at the
    /// previous look, and not written to for a while.
    nonisolated static func isSettled(
        _ recording: PendingRecording, previous: (size: Int64, modified: Date?)?, now: Date
    ) -> Bool {
        guard let previous, recording.size > 0, previous.size == recording.size,
            previous.modified == recording.modified, let modified = recording.modified
        else { return false }
        return now.timeIntervalSince(modified) >= settleSeconds
    }

    /// True when a recording arrived after automatic processing began.
    nonisolated static func isNew(_ recording: PendingRecording, since start: Date) -> Bool {
        guard let modified = recording.modified else { return false }
        return modified >= start
    }

    /// Where a waiting recording stands, in words, for the queue.
    func status(of recording: PendingRecording) -> String? {
        if let job = pipeline.job(for: recording.url) {
            return pipeline.current?.id == job.id ? "Processing now" : "Queued"
        }
        if let failure = failures[recording.url] { return failure }
        guard settings.config.bool(ConfigKey.autoProcess, default: true) else { return nil }
        guard Self.isNew(recording, since: processingSince) else {
            return "Was here before automatic processing, so it waits for you"
        }
        if monitor.status == .recording { return "Waits until the recording stops" }
        return attempted.contains(recording.url) ? nil : "Waiting for the file to finish writing"
    }

    /// Queue every waiting recording, oldest first: the backlog that was there
    /// before automatic processing, in one click rather than one per file.
    func processAllWaiting() {
        let waiting = queue.pending
            .filter { pipeline.job(for: $0.url) == nil }
            .sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        for recording in waiting {
            failures[recording.url] = nil
            attempted.insert(recording.url)
            pipeline.process(recording.url, automatic: true)
        }
    }

    /// Run a recording again after it failed or was cancelled.
    func retry(_ url: URL) {
        failures[url] = nil
        attempted.insert(url)
        pipeline.process(url)
    }

    // MARK: - Notes

    private func writeMissingNotes() {
        guard settings.config.bool(ConfigKey.autoNotes, default: true),
            settings.hasLLMCredential, !index.building
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.notesWindowDays * 86_400)
        for meeting in index.meetings where !meeting.hasNotes && !meeting.isLegacy {
            guard let date = meeting.date, date >= cutoff,
                !notesAttempted.contains(meeting.folder),
                !pipeline.has(.notes(meeting.folder))
            else { continue }
            notesAttempted.insert(meeting.folder)
            pipeline.notesFromTranscript(folder: meeting.folder, automatic: true)
        }
    }

    /// Meetings with a transcript and no notes, for the one-click catch-up.
    var meetingsMissingNotes: [URL] {
        index.meetings.filter { !$0.hasNotes || $0.isLegacy }.map(\.folder)
    }

    func writeNotes(for folders: [URL]) {
        for folder in folders where !pipeline.has(.notes(folder)) {
            notesAttempted.insert(folder)
            pipeline.notesFromTranscript(folder: folder, automatic: true)
        }
    }

    // MARK: - Voice Memos

    /// Voice Memos keeps its library in a group container that exists once the
    /// app has been used. Without it there is nothing to import, and trying
    /// every ten minutes would only fail every ten minutes.
    nonisolated static var voiceMemosLibraryExists: Bool {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.VoiceMemos.shared")
        return FileManager.default.fileExists(atPath: container.path(percentEncoded: false))
    }

    private func importVoiceMemos(now: Date = Date()) {
        guard settings.config.bool(ConfigKey.voiceMemos, default: true),
            voiceMemosBlocked == nil, Self.voiceMemosLibraryExists,
            !pipeline.has(.voiceMemos), monitor.status != .recording
        else { return }
        if let last = lastVoiceMemos, now.timeIntervalSince(last) < Self.voiceMemosInterval { return }
        lastVoiceMemos = now
        pipeline.importVoiceMemos(
            lookbackDays: settings.config.int(ConfigKey.voiceMemosLookback, default: 7),
            automatic: true)
    }

    /// Import now, and ask again for access if it was refused before.
    func importVoiceMemosNow() {
        voiceMemosBlocked = nil
        lastVoiceMemos = Date()
        pipeline.importVoiceMemos(
            lookbackDays: settings.config.int(ConfigKey.voiceMemosLookback, default: 7))
    }

    func openFullDiskAccessSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Reminders

    /// Sync once the index has settled. Debounced: a burst of store changes,
    /// most of them this app's own saves, becomes one sync.
    func scheduleRemindersSync(after seconds: Double) {
        remindersTask?.cancel()
        remindersTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            // New actions are only visible once the index has read them.
            var waited = 0
            while self?.index.building == true, waited < 300, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                waited += 1
            }
            guard !Task.isCancelled else { return }
            await self?.syncReminders(quiet: true)
        }
    }

    /// Adding new reminders is what the setting controls. Keeping the ones
    /// already there in step happens regardless: once an action is in
    /// Reminders, a tick on either side should never be lost.
    func syncReminders(quiet: Bool) async {
        guard reminders.authorised, !index.building else { return }
        let adding = settings.config.bool(ConfigKey.remindersSync, default: false)
        guard adding || reminders.hasSyncedItems else { return }
        completions.reload()
        await reminders.sync(
            candidates(onlyIn: nil, adding: adding), completions: completions,
            listID: settings.config.values[ConfigKey.remindersList],
            userName: settings.userName, quiet: quiet)
        lastReminders = Date()
    }

    /// Turn sync on: ask for access, then send what is in scope.
    func connectReminders() async {
        guard await reminders.connect() else { return }
        settings.setValue(ConfigKey.remindersSync, "true")
        await syncReminders(quiet: false)
    }

    /// Send one meeting's outstanding actions, whatever the scope says: the
    /// user asked for exactly these.
    func sendToReminders(meeting folder: URL) async {
        guard await reminders.connect() else { return }
        completions.reload()
        await reminders.sync(
            candidates(onlyIn: folder, adding: true), completions: completions,
            listID: settings.config.values[ConfigKey.remindersList],
            userName: settings.userName)
    }

    private func candidates(onlyIn folder: URL?, adding: Bool) -> [RemindersSync.Candidate] {
        let days = Double(settings.config.int(ConfigKey.remindersDays, default: 30))
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let scope = ReminderScope.from(settings.config.string(ConfigKey.remindersScope, default: "mine"))
        let user = settings.userName
        return index.allActions.compactMap { entry -> RemindersSync.Candidate? in
            if let folder, entry.meeting.folder != folder { return nil }
            let recent = entry.meeting.date.map { $0 >= cutoff } ?? false
            let eligible =
                folder != nil
                || (adding && recent && scope.includes(owner: entry.action.owner, userName: user))
            return RemindersSync.Candidate(
                key: Completions.key(meeting: entry.meeting.folder, action: entry.action),
                action: entry.action, meetingTitle: entry.meeting.title,
                meetingDate: entry.meeting.date, folder: entry.meeting.folder, eligible: eligible)
        }
    }

    // MARK: - After a run

    private func handle(_ completion: Pipeline.Completion) {
        switch completion.job.kind {
        case .process(let url), .reprocess(let url):
            switch completion.outcome {
            case .failed:
                failures[url] = "Failed: " + Self.reason(from: completion.output)
            case .cancelled:
                failures[url] = "Cancelled"
            case .busyElsewhere:
                failures[url] = "Being processed by another transcribe process"
            case .succeeded, .needsPermission:
                failures[url] = nil
            }
        case .voiceMemos:
            if completion.outcome == .needsPermission {
                voiceMemosBlocked =
                    "Importing Voice Memos needs Full Disk Access for Transcribe, "
                    + "which macOS only grants in System Settings."
            }
        default:
            break
        }

        // New and changed folders are invisible until the library is read
        // again. With more runs waiting, once a minute is enough; the last one
        // always refreshes.
        let due = lastRefresh.map { Date().timeIntervalSince($0) >= 60 } ?? true
        if pipeline.queued.isEmpty || due {
            Task { await refresh() }
        }
    }

    /// The last line that says what went wrong, rather than the whole log.
    nonisolated static func reason(from output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let telling = lines.last { line in
            line.hasPrefix("✗") || line.lowercased().contains("error")
                || line.lowercased().contains("warning")
        }
        let text = (telling ?? lines.last ?? "see the log").trimmingCharacters(
            in: CharacterSet(charactersIn: "✗ "))
        return text.count > 160 ? String(text.prefix(157)) + "…" : text
    }
}
