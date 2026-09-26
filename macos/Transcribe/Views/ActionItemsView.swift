import SwiftUI

/// Every action item from every meeting, in one list.
///
/// The pipeline already extracts these per meeting and then strands them there,
/// one folder deep. What you actually want to know is what you owe people
/// across all of them.
struct ActionItemsView: View {
    @Environment(MeetingIndex.self) private var index
    @Environment(Completions.self) private var completions
    @Environment(AppleExport.self) private var export
    @Environment(Settings.self) private var settings
    let onOpen: (URL) -> Void

    @State private var owner: String?
    @State private var showDone = false

    private var items: [(meeting: IndexedMeeting, action: IndexedMeeting.Action)] {
        index.allActions.filter { entry in
            if let owner, entry.action.assignedOwner != owner { return false }
            if !showDone,
                completions.isDone(meeting: entry.meeting.folder, action: entry.action)
            { return false }
            return true
        }
    }

    private var outstanding: Int {
        index.allActions.filter {
            !completions.isDone(meeting: $0.meeting.folder, action: $0.action)
        }.count
    }

    /// Exports what is on screen, not everything: the owner filter and the
    /// completed toggle are the user saying which actions they mean.
    private func sendToReminders() {
        let list = settings.config.values[ConfigKey.remindersList]
        let shown = items
        Task {
            for (meeting, action) in shown {
                await export.sendToReminders(
                    actions: [action],
                    meetingTitle: meeting.title,
                    meetingFolder: meeting.folder,
                    meetingDate: meeting.date,
                    listID: list,
                    dueDate: nil
                )
            }
        }
    }

    var body: some View {
        Group {
            if index.allActions.isEmpty {
                ContentUnavailableView {
                    Label("No action items", systemImage: "checklist")
                } description: {
                    Text(
                        index.building
                            ? "Still reading the library — \(Int(index.progress * 100))% indexed."
                            : "Meetings with generated notes contribute their next steps here."
                    )
                }
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing outstanding", systemImage: "checkmark.circle")
                } description: {
                    Text(owner.map { "Nothing left for \($0)." } ?? "Everything is ticked off.")
                } actions: {
                    Button("Show completed") { showDone = true }
                }
            } else {
                VStack(spacing: 0) {
                    if export.status != .idle { AppleExportBar() }
                    List {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                            ActionRow(meeting: entry.meeting, action: entry.action, onOpen: onOpen)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .navigationTitle("Action items")
        .navigationSubtitle("\(outstanding) outstanding")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Everyone") { owner = nil }
                    if !index.owners.isEmpty {
                        Divider()
                        ForEach(index.owners, id: \.self) { name in
                            Button {
                                owner = name
                            } label: {
                                if owner == name {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    }
                } label: {
                    Label(owner ?? "Everyone", systemImage: "person")
                }
                .help("Show only one person's actions")
            }
            ToolbarItem {
                Toggle(isOn: $showDone) {
                    Label("Completed", systemImage: "checkmark.circle")
                }
                .help("Include actions already ticked off")
            }
            ToolbarItem {
                Button {
                    sendToReminders()
                } label: {
                    Label("Send to Reminders", systemImage: "checklist")
                }
                .disabled(items.isEmpty || export.isWorking)
                .help("Add every action shown here to Reminders")
            }
        }
    }
}

private struct ActionRow: View {
    @Environment(Completions.self) private var completions
    let meeting: IndexedMeeting
    let action: IndexedMeeting.Action
    let onOpen: (URL) -> Void

    private var isDone: Bool {
        completions.isDone(meeting: meeting.folder, action: action)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                completions.setDone(!isDone, meeting: meeting.folder, action: action)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Mark as outstanding" : "Mark as done")
            .help(isDone ? "Mark as still outstanding" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.title)
                        .fontWeight(.medium)
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? .secondary : .primary)
                    if let owner = action.assignedOwner {
                        Text(owner)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                if !action.detail.isEmpty {
                    Text(action.detail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button {
                    onOpen(meeting.folder)
                } label: {
                    HStack(spacing: 4) {
                        Text(meeting.title)
                        if let date = meeting.date {
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
