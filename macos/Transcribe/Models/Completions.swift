import Foundation

/// Which action items have been done.
///
/// Kept in one file rather than per meeting: this is the app's own state about
/// a cross-meeting list, not something a meeting folder should carry, and a
/// single file means the action list does not touch 100 folders to render.
///
/// The command line reads and writes the same file (`transcribe actions done`),
/// so a tick in either place shows up in the other.
@MainActor
@Observable
final class Completions {
    private(set) var done: Set<String> = []

    /// Called with each key whose state the user changed here, so Reminders can
    /// be told straight away rather than at the next sync.
    var onChange: ((String, Bool) -> Void)?

    static let url: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".transcribe")
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return base.appending(path: "action-items-done.json")
    }()

    init() {
        reload()
    }

    /// Read the file again. The command line may have ticked something off
    /// since this was last read.
    func reload() {
        guard let data = try? Data(contentsOf: Self.url),
            let stored = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        let loaded = Set(stored.map(Self.normalise))
        if loaded != done { done = loaded }
    }

    /// Identity is the meeting plus the action's own text. A reprocessed
    /// meeting that produces the same action keeps its tick; one whose wording
    /// changes reappears, which is the safer way round.
    // Pure, so nonisolated: it inherits @MainActor from the class otherwise
    // and cannot be called from a test.
    nonisolated static func key(meeting: URL, action: IndexedMeeting.Action) -> String {
        "\(canonicalPath(meeting))|\(action.id)"
    }

    /// A directory URL may or may not end in a slash depending on how it was
    /// made, and the command line never writes one. Keys drop it, so the same
    /// meeting is one key whichever side wrote it.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// A key written before paths were canonical, brought into line.
    nonisolated static func normalise(_ key: String) -> String {
        guard let bar = key.firstIndex(of: "|") else { return key }
        var folder = String(key[..<bar])
        if folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        return folder + key[bar...]
    }

    func isDone(meeting: URL, action: IndexedMeeting.Action) -> Bool {
        done.contains(Self.key(meeting: meeting, action: action))
    }

    func isDone(key: String) -> Bool { done.contains(key) }

    func setDone(_ isDone: Bool, meeting: URL, action: IndexedMeeting.Action) {
        let key = Self.key(meeting: meeting, action: action)
        guard set(isDone, key: key) else { return }
        onChange?(key, isDone)
    }

    /// Apply a change that came from Reminders. Not echoed back through
    /// `onChange`, or every completion would be written to Reminders twice.
    func applyFromReminders(_ isDone: Bool, key: String) {
        set(isDone, key: key)
    }

    @discardableResult
    private func set(_ isDone: Bool, key: String) -> Bool {
        guard done.contains(key) != isDone else { return false }
        if isDone { done.insert(key) } else { done.remove(key) }
        save()
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(done).sorted()) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
