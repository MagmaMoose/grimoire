import SwiftUI

/// Every action item from every meeting, in one list.
///
/// The pipeline already extracts these per meeting and then strands them there,
/// one folder deep. What you actually want to know is what you owe people
/// across all of them. Reminders is where they get done: this list is the view
/// from the meetings' side, and the two stay in step.
struct ActionItemsView: View {
    @Environment(MeetingIndex.self) private var index
    @Environment(Completions.self) private var completions
    @Environment(Settings.self) private var settings
    let onOpen: (URL) -> Void

    @State private var filter: OwnerFilter = .everyone
    @State private var showCompleted = false
    /// Ticked a moment ago. Kept in place, struck through, for a few seconds,
    /// as Reminders does: an item that vanishes the instant it is clicked
    /// reads as deleted, not done.
    @State private var justTicked: Set<String> = []

    enum OwnerFilter: Hashable {
        case everyone
        case mine
        case person(String)

        var label: String {
            switch self {
            case .everyone: "Everyone"
            case .mine: "Mine"
            case .person(let name): name
            }
        }
    }

    struct Entry: Identifiable {
        let id: String
        let key: String
        let meeting: IndexedMeeting
        let action: IndexedMeeting.Action
    }

    /// Every action, each with a stable identity. Two identical actions in one
    /// meeting share a key, so an occurrence count keeps their rows apart.
    private var entries: [Entry] {
        var seen: [String: Int] = [:]
        return index.allActions.map { pair in
            let key = Completions.key(meeting: pair.meeting.folder, action: pair.action)
            let count = seen[key, default: 0]
            seen[key] = count + 1
            return Entry(id: "\(key)#\(count)", key: key, meeting: pair.meeting, action: pair.action)
        }
    }

    private var filtered: [Entry] {
        let user = settings.userName
        return entries.filter { entry in
            switch filter {
            case .everyone:
                return true
            case .mine:
                // Unassigned ones are nobody's yet, so they are yours to pick
                // up. The command line's --mine and the Reminders scope agree.
                return entry.action.assignedOwner == nil
                    || Owner.isUser(entry.action.owner, named: user)
            case .person(let name):
                return entry.action.assignedOwner?.caseInsensitiveCompare(name) == .orderedSame
            }
        }
    }

    private var outstanding: [Entry] {
        filtered.filter { !completions.isDone(key: $0.key) || justTicked.contains($0.key) }
    }

    private var completed: [Entry] {
        filtered.filter { completions.isDone(key: $0.key) && !justTicked.contains($0.key) }
    }

    private var outstandingCount: Int {
        entries.filter { !completions.isDone(key: $0.key) }.count
    }

    /// Real names only. "Speaker 1, Speaker 2, Speaker 3" filtered nothing a
    /// person could act on, and the user's own name is what Mine is for.
    private var people: [String] {
        let user = settings.userName
        return index.owners.filter { !Owner.isUser($0, named: user) }
    }

    var body: some View {
        VStack(spacing: 0) {
            RemindersBanner()
            Divider()
            content
        }
        .navigationTitle("Action items")
        .navigationSubtitle("\(outstandingCount) outstanding")
        .toolbar {
            if !people.isEmpty || !settings.userName.isEmpty {
                ToolbarItem {
                    Menu {
                        Picker("Show", selection: $filter) {
                            Text("Everyone").tag(OwnerFilter.everyone)
                            if !settings.userName.isEmpty {
                                Text("Mine and unassigned").tag(OwnerFilter.mine)
                            }
                            if !people.isEmpty {
                                Divider()
                                ForEach(people, id: \.self) { name in
                                    Text(name).tag(OwnerFilter.person(name))
                                }
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(filter.label, systemImage: "person.crop.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Show only one person's action items")
                }
            }
        }
        .onChange(of: settings.userName) {
            if filter == .mine, settings.userName.isEmpty { filter = .everyone }
        }
    }

    @ViewBuilder
    private var content: some View {
        if index.allActions.isEmpty {
            ContentUnavailableView {
                Label("No action items", systemImage: "checklist")
            } description: {
                Text(
                    index.building
                        ? "Still reading the library, \(Int(index.progress * 100))% indexed."
                        : "Meetings with generated notes contribute their next steps here."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView {
                Label("Nothing here", systemImage: "person.crop.circle.badge.checkmark")
            } description: {
                Text("No action items for \(filter.label).")
            } actions: {
                Button("Show everyone's") { filter = .everyone }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    if outstanding.isEmpty {
                        Label("Everything is done.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(outstanding) { entry in
                        ActionRow(entry: entry, onOpen: onOpen, onToggle: toggle)
                    }
                } header: {
                    Text("Outstanding")
                }

                if !completed.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showCompleted) {
                            ForEach(completed) { entry in
                                ActionRow(entry: entry, onOpen: onOpen, onToggle: toggle)
                            }
                        } label: {
                            Text("Completed (\(completed.count))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func toggle(_ entry: Entry) {
        let done = !completions.isDone(key: entry.key)
        completions.setDone(done, meeting: entry.meeting.folder, action: entry.action)
        guard done else {
            justTicked.remove(entry.key)
            return
        }
        justTicked.insert(entry.key)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            _ = withAnimation { justTicked.remove(entry.key) }
        }
    }
}

private struct ActionRow: View {
    @Environment(Completions.self) private var completions
    @Environment(RemindersSync.self) private var reminders
    let entry: ActionItemsView.Entry
    let onOpen: (URL) -> Void
    let onToggle: (ActionItemsView.Entry) -> Void

    private var isDone: Bool { completions.isDone(key: entry.key) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                onToggle(entry)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Mark as outstanding" : "Mark as done")
            .help(isDone ? "Mark as still outstanding" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.action.title)
                        .fontWeight(.medium)
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? .secondary : .primary)
                    if let owner = entry.action.assignedOwner {
                        Text(owner)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                    if reminders.isSynced(entry.key) {
                        Image(systemName: "checklist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("In Reminders")
                            .accessibilityLabel("In Reminders")
                    }
                }
                if !entry.action.detail.isEmpty {
                    Text(entry.action.detail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button {
                    onOpen(entry.meeting.folder)
                } label: {
                    HStack(spacing: 4) {
                        Text(entry.meeting.title)
                        if let date = entry.meeting.date {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)
                .help("Open the meeting this came from")
            }
        }
        .padding(.vertical, 3)
    }
}

/// Where Reminders stands, and the one button that changes it.
///
/// Connecting used to be an unlabelled icon in the toolbar, and the permission
/// prompt it raised could open behind the window. This says what happens and
/// where things will go before anything is asked.
struct RemindersBanner: View {
    @Environment(RemindersSync.self) private var reminders
    @Environment(Automation.self) private var automation
    @Environment(Settings.self) private var settings

    private var enabled: Bool { settings.config.bool(ConfigKey.remindersSync, default: false) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checklist")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            if reminders.authorised, enabled || reminders.hasSyncedItems {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kept in Reminders, in “\(reminders.listTitle ?? RemindersSync.defaultListName)”")
                        .fontWeight(.medium)
                    statusLine
                }
                Spacer()
                Button("Open Reminders") { reminders.openReminders() }
                Button("Sync Now") { Task { await automation.syncReminders(quiet: false) } }
                    .disabled(reminders.isWorking)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep these in Reminders").fontWeight(.medium)
                    Text(
                        "Your action items from recent meetings go into a “\(RemindersSync.defaultListName)” "
                            + "list. Tick one off in either app and it is ticked off in both."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if case .failed(let message) = reminders.status {
                        Text(message).font(.callout).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(reminders.authorised ? "Turn On" : "Connect Reminders…") {
                    Task { await automation.connectReminders() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }

    @ViewBuilder
    private var statusLine: some View {
        switch reminders.status {
        case .idle:
            if let last = reminders.lastSynced {
                Text("Last synced \(last.formatted(date: .omitted, time: .shortened)).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Ticks go both ways.").font(.callout).foregroundStyle(.secondary)
            }
        case .working(let label):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(label)…").font(.callout).foregroundStyle(.secondary)
            }
        case .done(let message):
            Text(message).font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        }
    }
}
