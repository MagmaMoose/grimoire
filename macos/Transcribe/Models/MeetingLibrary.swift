import Foundation

/// One meeting folder on disk.
///
/// Split in two on purpose. The name and the date are all the sidebar needs and
/// both come out of the folder name, so a list can be drawn without touching
/// the filesystem at all. Everything else costs a directory listing, which on
/// iCloud Drive means a round trip to the file provider: 105 folders measured
/// at 13 seconds of wall clock for 0.14s of CPU. Doing that before first paint
/// left the window on a spinner.
struct MeetingFolder: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let date: Date?

    /// Nil until the folder has been listed. See ``MeetingLibrary/contents(of:)``.
    var contents: Contents?

    // Identity is the folder, not its contents. The synthesised conformance
    // would include `contents`, and since the sidebar tags rows with the whole
    // value, filling that in mid-scan changes the tag and silently drops the
    // user's selection.
    static func == (lhs: MeetingFolder, rhs: MeetingFolder) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    struct Contents: Hashable, Sendable {
        var notesJSON: URL?
        var transcriptText: URL?
        var summaryText: URL?
        var notesHTML: URL?
        var media: URL?

        /// A directory with neither notes nor a transcript is something else
        /// that happens to live in the meetings folder.
        var isMeeting: Bool { notesJSON != nil || transcriptText != nil }

        /// Folders written before the JSON pipeline carry only a transcript and
        /// a summary. They are the bulk of an existing library, so they stay
        /// browsable rather than being hidden for lacking structure.
        var isLegacy: Bool { notesJSON == nil }
    }

    /// The folder name with its timestamp stripped, since the sidebar shows the
    /// date separately. Covers this pipeline's two prefixes and Teams'
    /// `Title-20241112_123724-Meeting Recording`, whose stamp and boilerplate
    /// suffix are both noise in a list.
    var displayName: String {
        var trimmed = Self.datePrefix.stringByReplacingMatches(
            in: name,
            range: NSRange(name.startIndex..., in: name),
            withTemplate: ""
        )
        trimmed = Self.teamsSuffix.stringByReplacingMatches(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed),
            withTemplate: ""
        )
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    private static let datePrefix = try! NSRegularExpression(
        pattern: "^\\d{4}-\\d{2}-\\d{2}[ T](\\d{2}-\\d{2}-\\d{2}|\\d{4})?\\s*"
    )

    private static let teamsSuffix = try! NSRegularExpression(
        pattern: "[-_]\\d{8}_\\d{6}[-_]Meeting Recording$"
    )
}

/// Scans a directory of meeting folders.
///
/// Two passes. The first lists the root and is enough to draw the sidebar. The
/// second fills in each folder's files in the background, at which point the
/// badges settle and anything that turned out not to be a meeting drops out.
/// Selecting a folder resolves that one immediately rather than waiting for the
/// pass to reach it.
@MainActor
@Observable
final class MeetingLibrary {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        /// The folder exists but this app cannot read it. Picking it in an open
        /// panel is what grants access, so this is a distinct state with its own
        /// call to action rather than a generic failure.
        case needsAccess(URL)
    }

    /// How long to wait for the first listing before assuming the folder is
    /// unreadable.
    ///
    /// A denied read of a protected location does not fail fast. macOS blocks
    /// the process inside `open(2)` and never returns, so there is nothing to
    /// catch and no error to report -- measured against an iCloud Drive folder
    /// that the same code lists in 0.04s from a terminal that holds the grant.
    /// Without a deadline the window simply spins forever.
    nonisolated static let listingSeconds: Double = 4

    private(set) var folders: [MeetingFolder] = []
    private(set) var phase: Phase = .idle
    private(set) var enriching = false
    var root: URL?

    /// Stamps each load so a slow one that finishes after a newer one cannot
    /// overwrite it. `@MainActor` serialises access to the properties, not the
    /// body of an async method, which is released at every await.
    private var loadID = 0
    private var enrichTask: Task<Void, Never>?

    /// Roots whose listing blocked past the deadline. Each attempt strands a
    /// worker on the shared queue for as long as the syscall hangs, so a user
    /// clicking Refresh repeatedly would starve every other background read.
    private var blockedRoots: Set<URL> = []

    /// Let a root be tried again, for the Choose Folder button, which is the
    /// action that actually changes the answer.
    func forget(root: URL) { blockedRoots.remove(root) }

    /// Runs blocking filesystem work off the main actor.
    ///
    /// A detached task is not enough. Under the Swift 5 language mode a closure
    /// written inside a `@MainActor` method picks up that isolation, so the
    /// work hops straight back to the main thread. Sampling the running app
    /// caught exactly that: every sample had the main thread parked inside
    /// `contentsOfDirectory`, which is the window not redrawing. An explicit
    /// queue hop cannot be undone by isolation inference.
    private nonisolated static let ioQueue = DispatchQueue(
        label: "com.magmamoose.transcribe.io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    nonisolated static func offMainActor<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    func load(root: URL?) async {
        loadID += 1
        let id = loadID
        enrichTask?.cancel()
        self.root = root

        guard let root else {
            folders = []
            phase = .failed("No meetings folder configured.")
            return
        }

        phase = .loading

        // Retrying a root already known to hang just strands another worker.
        if blockedRoots.contains(root) {
            folders = []
            phase = .needsAccess(root)
            return
        }

        guard let found = await Self.scanWithDeadline(root: root) else {
            guard id == loadID else { return }
            // Clear, or the previous folder's meetings stay live in the sidebar,
            // the search index and the action list while the screen says the
            // folder cannot be read.
            folders = []
            blockedRoots.insert(root)
            phase = .needsAccess(root)
            return
        }

        guard id == loadID else { return }
        blockedRoots.remove(root)
        folders = found
        phase =
            found.isEmpty
            ? .failed("Nothing in \(root.path(percentEncoded: false)).")
            : .loaded

        guard !found.isEmpty else { return }
        enrichTask = Task { await enrich(id: id) }
    }

    /// Resumes once, for whichever of the scan and the deadline lands first.
    ///
    /// `@unchecked Sendable` with an explicit lock: the two callers are on
    /// different queue threads, and a continuation resumed twice is a crash.
    private final class FirstWins: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[MeetingFolder]?, Never>?

        init(_ continuation: CheckedContinuation<[MeetingFolder]?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: [MeetingFolder]?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// The first listing, or nil if it did not come back in time.
    ///
    /// Not a task group. Leaving a `withTaskGroup` body implicitly awaits every
    /// remaining child, and `cancelAll()` only *requests* cancellation -- the
    /// scan is parked in a continuation around a blocking syscall and has no
    /// cancellation handler, so the group waited for it anyway and the deadline
    /// did nothing at all. Measured: a 2s deadline against a 10s block returned
    /// after 10s.
    ///
    /// The blocked thread cannot be cancelled, so it is abandoned. One stranded
    /// thread is a far better outcome than a window that never draws.
    private nonisolated static func scanWithDeadline(root: URL) async -> [MeetingFolder]? {
        await withCheckedContinuation { continuation in
            let once = FirstWins(continuation)
            // The queue is concurrent, so the deadline is not queued behind the
            // scan it is timing.
            ioQueue.async { once.resume(scan(root: root)) }
            ioQueue.asyncAfter(deadline: .now() + listingSeconds) { once.resume(nil) }
        }
    }

    /// Lists every folder's files, a few at a time, updating the list as each
    /// lands. Bounded because the file provider serves these one round trip at
    /// a time and queueing all 105 at once buys nothing.
    private func enrich(id: Int) async {
        enriching = true
        defer { if id == loadID { enriching = false } }

        let batchSize = 8
        var index = 0
        while index < folders.count {
            guard id == loadID, !Task.isCancelled else { return }

            let batch = folders[index..<min(index + batchSize, folders.count)].map(\.id)
            let resolved = await withTaskGroup(of: (URL, MeetingFolder.Contents).self) { group in
                for url in batch {
                    group.addTask { (url, Self.listContents(of: url)) }
                }
                var results: [URL: MeetingFolder.Contents] = [:]
                for await (url, contents) in group { results[url] = contents }
                return results
            }

            guard id == loadID, !Task.isCancelled else { return }
            for position in folders.indices where folders[position].contents == nil {
                if let contents = resolved[folders[position].id] {
                    folders[position].contents = contents
                }
            }
            index += batchSize
        }

        guard id == loadID, !Task.isCancelled else { return }
        // Only now is it known which directories were never meetings.
        folders.removeAll { $0.contents?.isMeeting == false }
        if folders.isEmpty, let root {
            phase = .failed("No meeting folders in \(root.path(percentEncoded: false)).")
        }
    }

    /// The files in one folder, listing it now if the background pass has not
    /// reached it yet. Selecting a meeting must not wait for the queue.
    func contents(of folder: MeetingFolder, refresh: Bool = false) async -> MeetingFolder.Contents {
        // `refresh` skips the cache: after the pipeline writes to a folder, the
        // cached listing describes what was there before it ran.
        if !refresh, let contents = folder.contents { return contents }
        let url = folder.id
        let contents = await Self.offMainActor { Self.listContents(of: url) }
        if let position = folders.firstIndex(where: { $0.id == url }) {
            folders[position].contents = contents
        }
        return contents
    }

    /// Reads one folder's `notes.json`. Off the main actor: the file runs to
    /// hundreds of kilobytes and parses hundreds of segments.
    nonisolated static func loadRecord(_ url: URL?) async throws -> MeetingRecord? {
        guard let url else { return nil }
        return try await offMainActor {
            Result {
                try PipelineDate.decoder().decode(
                    MeetingRecord.self, from: try Data(contentsOf: url))
            }
        }.get()
    }

    nonisolated static func loadText(_ url: URL?) async -> String? {
        guard let url else { return nil }
        return await offMainActor { try? String(contentsOf: url, encoding: .utf8) }
    }

    // MARK: - Scanning

    /// Lists the root only. No per-folder IO, so this stays fast on a network
    /// or cloud volume.
    nonisolated static func scan(root: URL) -> [MeetingFolder] {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        let folders = entries.compactMap { entry -> MeetingFolder? in
            guard
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            return MeetingFolder(
                id: entry,
                name: entry.lastPathComponent,
                date: folderDate(from: entry.lastPathComponent),
                contents: nil
            )
        }

        return folders.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?): return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.name > rhs.name
            }
        }
    }

    nonisolated static func listContents(of folder: URL) -> MeetingFolder.Contents {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return MeetingFolder.Contents() }

        let bySuffix = { (suffix: String) in
            files.first { $0.lastPathComponent.hasSuffix(suffix) }
        }

        return MeetingFolder.Contents(
            notesJSON: files.first { $0.lastPathComponent == "notes.json" },
            transcriptText: files.first { $0.lastPathComponent == "transcript.txt" }
                ?? bySuffix("_transcription.txt"),
            summaryText: files.first { $0.lastPathComponent == "summary.txt" }
                ?? bySuffix("_summary.txt"),
            notesHTML: files.first { $0.lastPathComponent == "notes.html" },
            media: Media.preferred(from: files)
        )
    }

    /// The date is read from the folder name rather than from the filesystem,
    /// whose creation dates do not survive an iCloud sync.
    ///
    /// Three naming schemes are in the wild, and the third is the majority of
    /// an existing library: this pipeline's `2026-08-27 1105 Title`, its older
    /// `2024-10-30 11-04-23 Title`, and Teams' own
    /// `Title-20241112_123724-Meeting Recording`, which carries its date in
    /// the middle rather than at the front.
    nonisolated static func folderDate(from name: String) -> Date? {
        for format in ["yyyy-MM-dd HHmm", "yyyy-MM-dd HH-mm-ss", "yyyy-MM-dd"] {
            if let date = formatter(format).date(from: String(name.prefix(format.count))) {
                return date
            }
        }
        if let match = embeddedStamp.firstMatch(
            in: name, range: NSRange(name.startIndex..., in: name)
        ), let range = Range(match.range(at: 1), in: name) {
            return formatter("yyyyMMdd_HHmmss").date(from: String(name[range]))
        }
        return nil
    }

    nonisolated static let embeddedStamp = try! NSRegularExpression(
        pattern: "[-_](\\d{8}_\\d{6})[-_]"
    )

    private nonisolated static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
