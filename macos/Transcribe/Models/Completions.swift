import Foundation

/// Which action items have been done.
///
/// Kept in one file rather than per meeting: this is the app's own state about
/// a cross-meeting list, not something a meeting folder should carry, and a
/// single file means the action list does not touch 100 folders to render.
@MainActor
@Observable
final class Completions {
    private(set) var done: Set<String> = []

    static let url: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".transcribe")
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return base.appending(path: "action-items-done.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.url),
            let stored = try? JSONDecoder().decode([String].self, from: data)
        {
            done = Set(stored)
        }
    }

    /// Identity is the meeting plus the action's own text. A reprocessed
    /// meeting that produces the same action keeps its tick; one whose wording
    /// changes reappears, which is the safer way round.
    // Pure, so nonisolated: it inherits @MainActor from the class otherwise
    // and cannot be called from a test.
    nonisolated static func key(meeting: URL, action: IndexedMeeting.Action) -> String {
        "\(meeting.path(percentEncoded: false))|\(action.id)"
    }

    func isDone(meeting: URL, action: IndexedMeeting.Action) -> Bool {
        done.contains(Self.key(meeting: meeting, action: action))
    }

    func setDone(_ isDone: Bool, meeting: URL, action: IndexedMeeting.Action) {
        let key = Self.key(meeting: meeting, action: action)
        if isDone { done.insert(key) } else { done.remove(key) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(done).sorted()) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
