import Foundation

/// A recording sitting in the watch folder, and whether it has been processed.
struct PendingRecording: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let modified: Date?
    /// A meeting folder in the destination that came from this file.
    let processedInto: [URL]

    var isProcessed: Bool { !processedInto.isEmpty }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// What is waiting in the watch folder.
///
/// Without this the pipeline is a black box: a recording either turns into a
/// meeting or it does not, and there is nowhere to see which. Matching each
/// file against `source_file` in the meetings already written is what makes
/// "this one never got processed" visible.
@MainActor
@Observable
final class WatchQueue {
    private(set) var recordings: [PendingRecording] = []
    private(set) var scanning = false
    private(set) var message: String?

    private var loadID = 0

    var pending: [PendingRecording] { recordings.filter { !$0.isProcessed } }

    /// Cached source-file basenames, so a refresh does not re-read and re-parse
    /// every meeting's notes.json. Keyed by folder, dropped when it disappears.
    private var sourceCache: [URL: String] = [:]

    func load(watch: URL?, library: [MeetingFolder]) async {
        loadID += 1
        let id = loadID
        // Both above the guard: a load with no watch folder used to return
        // before clearing `scanning`, leaving a spinner that never stopped
        // whenever it superseded a scan in flight.
        scanning = true
        defer { if id == loadID { scanning = false } }

        guard let watch else {
            recordings = []
            message = "No watch folder configured."
            return
        }

        // Which source files already produced a meeting. Read from the folders
        // themselves rather than guessed from names, because the pipeline
        // renames a meeting after what was said in it.
        let folders = library.map(\.id)
        let known = sourceCache
        let (found, sources) = await MeetingLibrary.offMainActor {
            Self.scan(watch: watch, meetingFolders: folders, cachedSources: known)
        }

        guard id == loadID else { return }
        sourceCache = sources
        recordings = found
        message =
            found.isEmpty
            ? "Nothing in \(watch.path(percentEncoded: false))."
            : nil
    }

    nonisolated static func scan(
        watch: URL, meetingFolders: [URL], cachedSources: [URL: String] = [:]
    ) -> (recordings: [PendingRecording], sources: [URL: String]) {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: watch,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return ([], cachedSources) }

        // basename of every source_file the library records, mapped to the
        // meeting folders it produced. Parsed once per folder and remembered,
        // because this ran over every meeting on every refresh.
        var sources: [URL: String] = [:]
        var producedBy: [String: [URL]] = [:]
        for folder in meetingFolders {
            if let cached = cachedSources[folder] {
                sources[folder] = cached
                producedBy[cached, default: []].append(folder)
                continue
            }
            let notes = folder.appending(path: "notes.json")
            guard
                let data = try? Data(contentsOf: notes),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let source = object["source_file"] as? String
            else { continue }
            let name = URL(filePath: source).lastPathComponent
            sources[folder] = name
            producedBy[name, default: []].append(folder)
        }

        let recordings =
            entries
            .filter { Media.extensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey,
                ])
                return PendingRecording(
                    url: url,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate,
                    // The pipeline moves the source in by default, so a file
                    // still here with a meeting naming it was left in place.
                    processedInto: producedBy[url.lastPathComponent] ?? []
                )
            }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return (recordings, sources)
    }
}
