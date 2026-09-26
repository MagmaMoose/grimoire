import Foundation

/// Categories on meetings, stored as `tags.json` inside each meeting folder.
///
/// Per-folder rather than one central index: a meeting folder is already the
/// unit that gets moved, synced and archived, so its labels travel with it. A
/// central file would be one rename away from being wrong, and would not
/// survive the folder being opened on another Mac through iCloud.
///
/// `notes.json` is left alone. That file is the pipeline's output and gets
/// rewritten whenever a meeting is reprocessed, which would silently discard
/// anything the app had added to it.
struct Tags: Codable, Sendable, Equatable {
    var names: [String] = []
    /// One value per grouping field, such as `["Company": "Acme"]`. The fields
    /// themselves are the user's, listed in `group_fields`, so a library can be
    /// grouped by client or project rather than only by what kind of meeting
    /// each one was.
    var fields: [String: String] = [:]

    static let filename = "tags.json"

    init(names: [String] = [], fields: [String: String] = [:]) {
        self.names = names
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey {
        case names, fields
    }

    // Both keys optional: files written before fields existed have only
    // `names`, and a file with only fields has no categories.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        names = try container.decodeIfPresent([String].self, forKey: .names) ?? []
        fields = try container.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(names, forKey: .names)
        // Left out when empty, so a file nobody grouped stays as it was.
        if !fields.isEmpty { try container.encode(fields, forKey: .fields) }
    }

    static func load(in folder: URL) -> Tags {
        let url = folder.appending(path: filename)
        guard
            let data = try? Data(contentsOf: url),
            let tags = try? JSONDecoder().decode(Tags.self, from: data)
        else { return Tags() }
        return tags
    }

    func save(in folder: URL) throws {
        let url = folder.appending(path: Self.filename)
        guard !names.isEmpty || !fields.isEmpty else {
            // An empty file is just clutter in a folder the user browses.
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Every tag in use across the library, so the sidebar can offer them and the
/// same category is not retyped three different ways.
@MainActor
@Observable
final class TagIndex {
    private(set) var byFolder: [URL: [String]] = [:]
    private(set) var fieldsByFolder: [URL: [String: String]] = [:]

    /// Stamps each load so a slow one cannot publish over a newer one, or over
    /// a tag the user set while it was reading.
    private var loadID = 0

    var allTags: [String] {
        Array(Set(byFolder.values.flatMap { $0 })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func tags(for folder: URL) -> [String] { byFolder[folder] ?? [] }

    func value(of field: String, for folder: URL) -> String? { fieldsByFolder[folder]?[field] }

    /// Every value `field` has across the library, so the same company is not
    /// typed three different ways.
    func values(of field: String) -> [String] {
        Array(Set(fieldsByFolder.values.compactMap { $0[field] })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Set a folder's tags, writing the file off the main actor.
    ///
    /// The folder is usually on iCloud Drive, where a write is a round trip to
    /// the file provider; doing it inline froze the window on every click.
    func set(_ tags: [String], for folder: URL) async throws {
        let cleaned = Self.normalise(tags)
        byFolder[folder] = cleaned.isEmpty ? nil : cleaned
        try await write(folder)
    }

    /// Set one grouping field, or clear it with nil or an empty value.
    func set(field: String, to value: String?, for folder: URL) async throws {
        let cleaned = value?.trimmingCharacters(in: .whitespaces) ?? ""
        var fields = fieldsByFolder[folder] ?? [:]
        fields[field] = cleaned.isEmpty ? nil : cleaned
        fieldsByFolder[folder] = fields.isEmpty ? nil : fields
        try await write(folder)
    }

    /// Both halves are written together, from what is in memory, so setting a
    /// category never drops a field and the reverse.
    private func write(_ folder: URL) async throws {
        let tags = Tags(names: byFolder[folder] ?? [], fields: fieldsByFolder[folder] ?? [:])
        let failure = await MeetingLibrary.offMainActor { () -> Error? in
            do {
                try tags.save(in: folder)
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw failure }
    }

    func toggle(_ tag: String, for folder: URL) async throws {
        var current = tags(for: folder)
        if let index = current.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        {
            current.remove(at: index)
        } else {
            current.append(tag)
        }
        try await set(current, for: folder)
    }

    /// Reads the tag files. Cheap enough to do for the whole library because
    /// each is a few hundred bytes, but it still runs off the main actor since
    /// the folders may be on iCloud.
    func load(folders: [MeetingFolder]) async {
        loadID += 1
        let id = loadID
        let urls = folders.map(\.id)
        let loaded = await MeetingLibrary.offMainActor {
            var names: [URL: [String]] = [:]
            var fields: [URL: [String: String]] = [:]
            for url in urls {
                let tags = Tags.load(in: url)
                if !tags.names.isEmpty { names[url] = tags.names }
                if !tags.fields.isEmpty { fields[url] = tags.fields }
            }
            return (names, fields)
        }
        // A tag set while this was reading would otherwise be wiped by a
        // snapshot taken before it.
        guard id == loadID else { return }
        byFolder = loaded.0
        fieldsByFolder = loaded.1
    }

    /// Trim, drop blanks, and remove case-insensitive duplicates while keeping
    /// the spelling the user typed first.
    // Pure, so nonisolated: it inherits @MainActor from the class otherwise,
    // which makes it uncallable from a test and from the scan.
    nonisolated static func normalise(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}
