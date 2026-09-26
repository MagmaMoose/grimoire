import AppKit
import EventKit
import Foundation

/// Keeps action items in a Reminders list, ticked off in both directions.
///
/// Reminders is the task list. It already syncs to the phone and the watch,
/// already nags, already has due dates; a checklist inside this app would be a
/// worse copy of it. So an action item becomes a reminder in one named list,
/// once, and completing it on either side completes it on the other.
///
/// The previous export sent whatever was on screen one action at a time. Each
/// call replaced the status, so ten actions ended with "Added 1 reminder(s) to
/// Reminders", which read as one of ten and named a list called Reminders.
/// Sending twice added everything twice.
@MainActor
@Observable
final class RemindersSync {
    enum Status: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    /// One action item, and whether it should be added if it is not there yet.
    struct Candidate {
        let key: String
        let action: IndexedMeeting.Action
        let meetingTitle: String
        let meetingDate: Date?
        let folder: URL
        /// In scope for adding. An action that is already in Reminders is kept
        /// in step whether or not it still is.
        let eligible: Bool
    }

    private(set) var status: Status = .idle
    private(set) var lastSynced: Date?
    /// The list items went into, once known.
    private(set) var listTitle: String?

    private let export: AppleExport
    private var ledger = ReminderLedger.load()
    private var running = false

    /// The list a user who has not picked one gets.
    static let defaultListName = "Meetings"

    init(export: AppleExport) {
        self.export = export
    }

    var authorised: Bool { export.remindersAuthorised }
    var isWorking: Bool { if case .working = status { return true } else { return false } }

    func clear() { status = .idle }

    /// Whether this action already has a reminder.
    func isSynced(_ key: String) -> Bool { ledger.items[key] != nil }

    /// True once anything has been sent, which is what keeps completions in
    /// step even with automatic adding switched off.
    var hasSyncedItems: Bool { !ledger.items.isEmpty }

    /// Ask for access. The app is brought forward first: a permission prompt
    /// raised by a window that is not frontmost can open behind it, which is
    /// how the Allow button ended up hard to find.
    func connect() async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard await export.requestRemindersAccess() else {
            status = .failed(
                "Reminders access was refused. Allow it in System Settings > Privacy & Security > Reminders."
            )
            return false
        }
        return true
    }

    func openReminders() {
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Reminders.app"))
    }

    /// Bring Reminders and the app into agreement.
    ///
    /// Adds a reminder for each eligible action that is outstanding and has
    /// never been sent, and reconciles done-ness for every action that has.
    func sync(
        _ candidates: [Candidate],
        completions: Completions,
        listID: String?,
        userName: String,
        quiet: Bool = false
    ) async {
        guard !running else { return }
        guard authorised else {
            if !quiet { status = .failed("Transcribe does not have access to Reminders yet.") }
            return
        }
        running = true
        defer { running = false }
        if !quiet { status = .working("Syncing with Reminders") }

        let store = export.store
        let list: EKCalendar
        do {
            guard let found = try resolveList(store: store, listID: listID) else {
                status = .failed("There is no Reminders account to create the list in.")
                return
            }
            list = found
        } catch {
            status = .failed("Could not create the Reminders list: \(error.localizedDescription)")
            return
        }
        listTitle = list.title

        let existing = await Self.fetchReminders(in: list, store: store)
        var byID: [String: EKReminder] = [:]
        var byRef: [String: EKReminder] = [:]
        for reminder in existing {
            byID[reminder.calendarItemIdentifier] = reminder
            if let ref = ReminderLedger.ref(inNotes: reminder.notes) { byRef[ref] = reminder }
        }

        var added = 0
        var pushed = 0
        var pulled = 0
        var pending = false

        do {
            for candidate in candidates {
                let key = candidate.key
                let ref = ReminderLedger.ref(for: key)
                let appDone = completions.isDone(key: key)

                if var entry = ledger.items[key] {
                    guard let reminder = byID[entry.reminder] ?? byRef[entry.ref] else {
                        // Deleted in Reminders. That is the user saying they
                        // are finished with it, so it counts as done here too,
                        // and it is never put back.
                        ledger.items[key] = nil
                        ledger.dismissed.insert(key)
                        if !appDone {
                            completions.applyFromReminders(true, key: key)
                            pulled += 1
                        }
                        continue
                    }
                    entry.reminder = reminder.calendarItemIdentifier
                    switch ReminderMerge.resolve(
                        app: appDone, reminder: reminder.isCompleted, last: entry.done)
                    {
                    case .agreed(let done):
                        entry.done = done
                    case .push(let done):
                        reminder.isCompleted = done
                        try store.save(reminder, commit: false)
                        pending = true
                        entry.done = done
                        pushed += 1
                    case .pull(let done):
                        completions.applyFromReminders(done, key: key)
                        entry.done = done
                        pulled += 1
                    }
                    ledger.items[key] = entry
                    continue
                }

                if let reminder = byRef[ref] {
                    // Ours, but the ledger lost track of it. Adopted rather than
                    // duplicated; done on either side wins.
                    let done = appDone || reminder.isCompleted
                    if done, !reminder.isCompleted {
                        reminder.isCompleted = true
                        try store.save(reminder, commit: false)
                        pending = true
                    } else if done, !appDone {
                        completions.applyFromReminders(true, key: key)
                    }
                    ledger.items[key] = ReminderLedger.Entry(
                        reminder: reminder.calendarItemIdentifier, ref: ref, done: done)
                    continue
                }

                guard candidate.eligible, !appDone, !ledger.dismissed.contains(key) else { continue }
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                reminder.title = ReminderContent.title(for: candidate.action, userName: userName)
                reminder.notes = ReminderContent.notes(
                    for: candidate.action, meetingTitle: candidate.meetingTitle,
                    meetingDate: candidate.meetingDate, ref: ref)
                // Opens the meeting's folder from the reminder.
                reminder.url = candidate.folder
                try store.save(reminder, commit: false)
                pending = true
                ledger.items[key] = ReminderLedger.Entry(
                    reminder: reminder.calendarItemIdentifier, ref: ref, done: false)
                added += 1
            }
        } catch {
            store.reset()
            status = .failed("Could not update Reminders: \(error.localizedDescription)")
            return
        }

        if pending {
            // One commit for the batch; committing per reminder is markedly
            // slower and can leave half a meeting's actions behind.
            do {
                try store.commit()
            } catch {
                store.reset()
                status = .failed("Could not save to Reminders: \(error.localizedDescription)")
                return
            }
        }

        ledger.list = list.calendarIdentifier
        do {
            try ledger.save()
        } catch {
            status = .failed("Could not record what was sent to Reminders: \(error.localizedDescription)")
            return
        }
        lastSynced = Date()

        let summary = Self.summary(added: added, pushed: pushed, pulled: pulled, list: list.title)
        if let summary {
            status = .done(summary)
        } else if !quiet {
            status = .done("Reminders is up to date. Action items are in “\(list.title)”.")
        }
    }

    /// Tell Reminders about one tick straight away, rather than at the next
    /// sync. Only for actions that already have a reminder.
    func push(key: String, done: Bool) {
        guard authorised, var entry = ledger.items[key] else { return }
        let store = export.store
        guard let reminder = store.calendarItem(withIdentifier: entry.reminder) as? EKReminder
        else { return }
        if reminder.isCompleted != done {
            reminder.isCompleted = done
            do {
                try store.save(reminder, commit: true)
            } catch {
                status = .failed("Could not update Reminders: \(error.localizedDescription)")
                return
            }
        }
        entry.done = done
        ledger.items[key] = entry
        try? ledger.save()
    }

    /// Plain words for what a sync did, or nil when it did nothing.
    nonisolated static func summary(added: Int, pushed: Int, pulled: Int, list: String) -> String? {
        var parts: [String] = []
        if added > 0 {
            parts.append("Added \(added) action item\(added == 1 ? "" : "s") to “\(list)” in Reminders")
        }
        if pushed > 0 {
            parts.append("updated \(pushed) in Reminders")
        }
        if pulled > 0 {
            parts.append("picked up \(pulled) change\(pulled == 1 ? "" : "s") made in Reminders")
        }
        guard !parts.isEmpty else { return nil }
        var sentence = parts.joined(separator: ", ")
        sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
        return sentence + "."
    }

    /// The list to use: the one chosen in Settings, then the one used last
    /// time, then one called "Meetings", created if need be.
    private func resolveList(store: EKEventStore, listID: String?) throws -> EKCalendar? {
        if let listID, !listID.isEmpty, let chosen = store.calendar(withIdentifier: listID) {
            return chosen
        }
        if let previous = ledger.list, let list = store.calendar(withIdentifier: previous) {
            return list
        }
        let name = Self.defaultListName
        if let named = store.calendars(for: .reminder).first(where: {
            $0.title.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return named
        }
        // Beside the user's other lists, so it syncs wherever they do.
        guard
            let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local })
        else { return nil }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = name
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }

    private static func fetchReminders(in list: EKCalendar, store: EKEventStore) async -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [list])
        return await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }
}
