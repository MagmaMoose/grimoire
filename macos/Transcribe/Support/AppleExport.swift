import EventKit
import Foundation
import SwiftUI

/// Sends meetings to Notes, and holds the Reminders access that `RemindersSync`
/// uses to keep action items there.
///
/// Two very different mechanisms, because Apple provides for one and not the
/// other. Reminders has EventKit, a real API with a real permission. Notes has
/// no public API at all, so the only route is AppleScript, which brings the
/// automation permission and a quoting problem with it.
@MainActor
@Observable
final class AppleExport {
    enum Status: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Shared with `RemindersSync`. Apple asks for one store per app: each one
    /// is expensive to create and keeps its own cache of the database.
    let store = EKEventStore()

    /// Reminder lists to choose from, once access has been granted.
    private(set) var reminderLists: [(id: String, title: String)] = []

    var isWorking: Bool { if case .working = status { return true } else { return false } }

    func clear() { status = .idle }

    // MARK: - Reminders

    /// macOS 14 replaced `requestAccess(to:)` with a reminders-specific call,
    /// and the old one now returns denied on newer systems even when the user
    /// would have said yes.
    func requestRemindersAccess() async -> Bool {
        if remindersAuthorised { return true }
        do {
            let granted = try await store.requestFullAccessToReminders()
            if granted {
                // A store made before access was granted can go on reporting
                // no lists at all until it is told to look again.
                store.reset()
                await loadReminderLists()
            }
            return granted
        } catch {
            status = .failed("Reminders access failed: \(error.localizedDescription)")
            return false
        }
    }

    var remindersAuthorised: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func loadReminderLists() async {
        guard remindersAuthorised else { return }
        reminderLists = store.calendars(for: .reminder)
            .map { (id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Notes

    /// Send a meeting's notes to Apple Notes.
    ///
    /// Notes has no public API, so this drives it with AppleScript. The note
    /// body is written to a temporary file and the script reads it back, which
    /// means no meeting text is ever interpolated into script source. That is
    /// not a style choice: a transcript containing a quote or a backslash would
    /// otherwise produce a syntax error at best and arbitrary script at worst.
    func sendToNotes(html: String, title: String, folder: String) async {
        status = .working("Sending to Notes")

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "transcribe-note-\(UUID().uuidString).html")
        do {
            try Data(html.utf8).write(to: temporary, options: .atomic)
        } catch {
            status = .failed("Could not prepare the note: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let script = Self.notesScript(
            bodyFile: temporary.path(percentEncoded: false),
            folder: folder
        )

        let result = await Self.runAppleScript(script)
        switch result {
        case .success:
            status = .done("Added “\(title)” to Notes")
        case .failure(let message):
            status = .failed(message)
        }
    }

    /// The AppleScript. Only paths and the folder name are interpolated, and
    /// both are escaped; the note body arrives via the file.
    ///
    /// `nonisolated` here and on `escape`: a static on a @MainActor type
    /// inherits that isolation, which makes it uncallable from a test.
    nonisolated static func notesScript(bodyFile: String, folder: String) -> String {
        """
        set bodyText to (read POSIX file "\(escape(bodyFile))" as «class utf8»)
        tell application "Notes"
            if not (exists folder "\(escape(folder))") then
                make new folder with properties {name:"\(escape(folder))"}
            end if
            tell folder "\(escape(folder))"
                make new note with properties {body:bodyText}
            end tell
        end tell
        """
    }

    /// Escape a value for an AppleScript string literal.
    ///
    /// Backslash first: escaping the quotes first would then double the
    /// backslashes this adds.
    nonisolated static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    enum ScriptResult: Equatable {
        case success(String)
        case failure(String)
    }

    /// Run AppleScript out of process.
    ///
    /// `osascript` rather than `NSAppleScript`: NSAppleScript must run on the
    /// main thread, and a Notes script that prompts for automation consent can
    /// sit there for as long as the user takes to answer it.
    nonisolated static func runAppleScript(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/osascript")
                process.arguments = ["-"]

                let input = Pipe()
                let output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = output

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        returning: .failure("Could not run osascript: \(error.localizedDescription)"))
                    return
                }

                input.fileHandleForWriting.write(Data(source.utf8))
                input.fileHandleForWriting.closeFile()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let text = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(text))
                } else if text.contains("-1743") || text.lowercased().contains("not authorized") {
                    // The automation consent prompt was declined, or never
                    // appeared because the app has no usage description.
                    continuation.resume(
                        returning: .failure(
                            "Transcribe is not allowed to control Notes. Grant it in System "
                                + "Settings > Privacy & Security > Automation."))
                } else {
                    continuation.resume(
                        returning: .failure(text.isEmpty ? "Notes refused the request." : text))
                }
            }
        }
    }
}

/// Renders a meeting as the HTML Notes expects.
///
/// Notes accepts a small subset of HTML in a note body. Headings, paragraphs,
/// lists and links survive; stylesheets and most attributes do not, so this
/// stays deliberately plain rather than reusing the pipeline's styled export.
enum NoteBody {
    static func html(for record: MeetingRecord, folder: URL, date: Date?) -> String {
        // Built as head + body + footer so the footer cannot be skipped by an
        // early return. `defer` does not work for this: it runs after the
        // return value has already been computed.
        var parts = heading(for: record, date: date)
        parts += body(for: record)
        parts.append("<hr><p><i>\(escape(folder.path(percentEncoded: false)))</i></p>")
        return parts.joined(separator: "\n")
    }

    private static func heading(for record: MeetingRecord, date: Date?) -> [String] {
        var parts = ["<h1>\(escape(record.displayTitle))</h1>"]
        var meta: [String] = []
        if let date { meta.append(escape(date.formatted(date: .long, time: .shortened))) }
        if let minutes = Timecode.minutes(from: record.durationSeconds) {
            meta.append("\(minutes) minutes")
        }
        if !record.attendees.isEmpty {
            meta.append(escape(record.attendees.joined(separator: ", ")))
        }
        if !meta.isEmpty { parts.append("<p><i>\(meta.joined(separator: " · "))</i></p>") }
        return parts
    }

    private static func body(for record: MeetingRecord) -> [String] {
        guard let notes = record.notes else {
            return ["<p>No generated notes for this meeting.</p>"]
        }

        var parts: [String] = []
        if let summary = notes.summary, !summary.isEmpty {
            parts.append("<p>\(escape(summary))</p>")
        }

        if !notes.nextSteps.isEmpty {
            parts.append("<h2>Next steps</h2><ul>")
            for step in notes.nextSteps {
                let owner = step.assignedOwner.map { " — \(escape($0))" } ?? ""
                let detail = step.detail.isEmpty ? "" : ": \(escape(step.detail))"
                parts.append("<li><b>\(escape(step.title))</b>\(owner)\(detail)</li>")
            }
            parts.append("</ul>")
        }

        if !notes.decisions.isEmpty {
            parts.append("<h2>Decisions</h2><ul>")
            for decision in notes.decisions {
                let state = decision.status == .aligned ? "Agreed" : "Open"
                parts.append(
                    "<li><b>\(escape(decision.title))</b> (\(state)): \(escape(decision.detail))</li>"
                )
            }
            parts.append("</ul>")
        }

        for section in notes.sections {
            parts.append("<h2>\(escape(section.heading))</h2><p>\(escape(section.body))</p>")
        }

        if !notes.details.isEmpty {
            parts.append("<h2>Walkthrough</h2>")
            for detail in notes.details {
                let stamps =
                    detail.timestamps.isEmpty
                    ? ""
                    : " <i>(\(escape(detail.timestamps.joined(separator: ", "))))</i>"
                parts.append(
                    "<h3>\(escape(detail.heading))\(stamps)</h3><p>\(escape(detail.body))</p>")
            }
        }
        return parts
    }

    /// Escape text for HTML. Ampersand first, or it would double-escape the
    /// entities the later replacements introduce.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
