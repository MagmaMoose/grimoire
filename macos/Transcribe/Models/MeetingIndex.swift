import Foundation

/// One meeting, reduced to what search and the action list need.
struct IndexedMeeting: Codable, Sendable, Identifiable {
    var id: URL { folder }
    let folder: URL
    let name: String
    let title: String
    let date: Date?
    let isLegacy: Bool
    /// When the file this entry was built from last changed. Without it a
    /// reprocessed meeting keeps its old index entry forever, and the stale
    /// entry is written straight back to the cache.
    let stamp: Date?
    /// Everything searchable, already lowercased. Held separately from the
    /// lines so a miss costs one `contains` rather than a walk of every line.
    let haystack: String
    let lines: [Line]
    let actions: [Action]

    struct Line: Codable, Sendable, Hashable {
        let seconds: Double
        let timestamp: String
        let speaker: String?
        let text: String
    }

    struct Action: Codable, Sendable, Hashable, Identifiable {
        var id: String { owner + title + detail }
        let owner: String
        let title: String
        let detail: String

        var assignedOwner: String? { Owner.named(owner) }
    }

    /// Lines matching `query`, with enough context to be worth reading.
    func matches(_ query: String, limit: Int = 6) -> [Line] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var found: [Line] = []
        for line in lines where line.text.lowercased().contains(needle) {
            found.append(line)
            if found.count == limit { break }
        }
        return found
    }
}

/// Everything the library holds, searchable.
///
/// Built in the background and cached, because reading 100+ transcripts off
/// iCloud is slow enough to be worth doing once. Each entry records the
/// modification date of the file it was built from, so a reprocessed meeting
/// reindexes and the rest do not.
@MainActor
@Observable
final class MeetingIndex {
    private(set) var meetings: [IndexedMeeting] = []
    private(set) var building = false
    private(set) var progress: Double = 0

    private var task: Task<Void, Never>?
    /// Stamps each build. `Task.isCancelled` alone is not enough: the check has
    /// to happen after every await, and a cancelled build could still publish
    /// its last batch over a newer one.
    private var buildID = 0

    // nonisolated because the cache is read and written off the main actor.
    // A static on a @MainActor type inherits that isolation: a warning today,
    // an error under the Swift 6 language mode.
    nonisolated static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.magmamoose.transcribe")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "index-v2.json")
    }()

    /// Every action item across the library, newest meeting first.
    var allActions: [(meeting: IndexedMeeting, action: IndexedMeeting.Action)] {
        meetings
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .flatMap { meeting in meeting.actions.map { (meeting, $0) } }
    }

    var owners: [String] {
        Array(Set(allActions.compactMap { $0.action.assignedOwner })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func search(_ query: String) -> [IndexedMeeting] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return meetings.filter { $0.haystack.contains(needle) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        building = false
    }

    /// Index the library, reusing anything unchanged since last time.
    func build(folders: [MeetingFolder]) {
        cancel()
        guard !folders.isEmpty else {
            meetings = []
            return
        }

        buildID += 1
        let id = buildID
        building = true
        progress = 0
        let cached = meetings

        task = Task { [weak self] in
            let stale = await MeetingIndex.loadCache()
            // Merged, not either/or: an interrupted build leaves a handful of
            // in-memory entries, and preferring those would throw away the
            // hundreds on disk. `uniquingKeysWith` also avoids the trap that
            // `uniqueKeysWithValues` raises on a duplicate folder URL.
            var merged = Dictionary(stale.map { ($0.folder, $0) }, uniquingKeysWith: { _, new in new })
            for meeting in cached { merged[meeting.folder] = meeting }
            // Immutable before the loop below captures it; a captured `var` in
            // concurrent code is a Swift 6 error.
            let existing = merged

            var built: [IndexedMeeting] = []
            let total = Double(folders.count)

            for (position, folder) in folders.enumerated() {
                if Task.isCancelled { return }
                let indexed = await MeetingLibrary.offMainActor {
                    MeetingIndex.index(folder: folder, reusing: existing[folder.id])
                }
                built.append(indexed)
                // Publishing per folder keeps search usable while it builds.
                guard let self, id == self.buildID, !Task.isCancelled else { return }
                self.meetings = built
                self.progress = Double(position + 1) / total
            }

            guard let self, id == self.buildID, !Task.isCancelled else { return }
            self.building = false
            self.progress = 1
            let snapshot = built
            Task.detached(priority: .background) { MeetingIndex.saveCache(snapshot) }
        }
    }

    // MARK: - Indexing one folder

    /// Read a folder into the index, or reuse the cached entry when the folder
    /// has not changed since it was made.
    nonisolated static func index(
        folder: MeetingFolder, reusing cached: IndexedMeeting?
    ) -> IndexedMeeting {
        let contents = folder.contents ?? MeetingLibrary.listContents(of: folder.id)

        let source = contents.notesJSON ?? contents.transcriptText
        let stamp = source.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        // Reuse only when the source file has not changed since. The previous
        // test compared `isLegacy` and a non-empty haystack, which is always
        // true because the haystack contains the folder name, so nothing was
        // ever reindexed.
        if let cached, let stamp, cached.stamp == stamp, cached.isLegacy == contents.isLegacy {
            return cached
        }

        var title = folder.displayName
        var lines: [IndexedMeeting.Line] = []
        var actions: [IndexedMeeting.Action] = []
        var extra: [String] = []

        if let url = contents.notesJSON,
            let data = try? Data(contentsOf: url),
            let record = try? PipelineDate.decoder().decode(MeetingRecord.self, from: data)
        {
            title = record.displayTitle
            lines = record.segments.map {
                IndexedMeeting.Line(
                    seconds: $0.start, timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text)
            }
            if let notes = record.notes {
                extra.append(notes.summary ?? "")
                extra.append(contentsOf: notes.sections.map { "\($0.heading) \($0.body)" })
                extra.append(contentsOf: notes.details.map { "\($0.heading) \($0.body)" })
                extra.append(contentsOf: notes.decisions.map { "\($0.title) \($0.detail)" })
                actions = notes.nextSteps.map {
                    IndexedMeeting.Action(owner: $0.owner, title: $0.title, detail: $0.detail)
                }
            }
            extra.append(contentsOf: record.attendees)
            extra.append(record.calendarEvent?.title ?? "")
        } else if let url = contents.transcriptText,
            let text = try? String(contentsOf: url, encoding: .utf8)
        {
            // Older folders hold one unstructured blob. Splitting on sentences
            // gives search something to show, though there is no timing to
            // jump to.
            lines = text.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map {
                    IndexedMeeting.Line(
                        seconds: 0, timestamp: "", speaker: nil,
                        text: String($0).trimmingCharacters(in: .whitespaces))
                }
        }

        if let url = contents.summaryText,
            let summary = try? String(contentsOf: url, encoding: .utf8)
        {
            extra.append(summary)
        }

        let haystack = ([folder.name, title] + extra + lines.map(\.text))
            .joined(separator: "\n")
            .lowercased()

        return IndexedMeeting(
            folder: folder.id,
            name: folder.name,
            title: title,
            date: folder.date,
            isLegacy: contents.isLegacy,
            stamp: stamp,
            haystack: haystack,
            lines: lines,
            actions: actions
        )
    }

    // MARK: - Cache

    nonisolated static func loadCache() async -> [IndexedMeeting] {
        await MeetingLibrary.offMainActor {
            guard let data = try? Data(contentsOf: cacheURL) else { return [] }
            return (try? JSONDecoder().decode([IndexedMeeting].self, from: data)) ?? []
        }
    }

    nonisolated static func saveCache(_ meetings: [IndexedMeeting]) {
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
