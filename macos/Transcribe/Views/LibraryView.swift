import SwiftUI

/// The main window: meetings down the left, whatever is selected on the right.
struct LibraryView: View {
    @Environment(Settings.self) private var settings
    @Environment(TagIndex.self) private var tags
    @Environment(MeetingIndex.self) private var index
    @Environment(Pipeline.self) private var pipeline
    @Environment(WatchQueue.self) private var queue
    @Environment(MeetingLibrary.self) private var library
    @Environment(AppCommands.self) private var commands
    @Environment(Automation.self) private var automation
    @Environment(Completions.self) private var completions

    @State private var selection: Selection?
    @State private var search = ""
    @State private var tagFilter: String?
    /// Set when a search result is opened, so the meeting can jump straight to
    /// the line that matched.
    @State private var pendingSeek: Double?
    @State private var seekTarget: URL?
    @State private var lastMeeting: MeetingFolder?
    @State private var viewingResult = false
    /// A folder a run renamed while it was selected, to select again once the
    /// library has read it under its new name.
    @State private var followRename: String?
    @State private var addingGrouping = false
    @State private var newGrouping = ""
    @AppStorage("libraryGroupBy") private var groupingID = LibraryGrouping.month.id

    /// What the detail pane is showing. A meeting is one case among several so
    /// the action list and the queue are first-class destinations rather than
    /// sheets bolted onto the side.
    enum Selection: Hashable {
        case meeting(MeetingFolder)
        case actions
        case queue
    }

    private var grouping: LibraryGrouping {
        let chosen = LibraryGrouping(id: groupingID)
        // A field removed in Settings falls back rather than grouping every
        // meeting under "No Company".
        if case .field(let name) = chosen, !groupFields.contains(name) { return .month }
        return chosen
    }

    private var groupFields: [String] { settings.list(ConfigKey.groupFields) }

    /// True while the results list should be showing.
    ///
    /// Opening a result used to clear the search box, which threw away the
    /// query the user had typed. The query stays; this just steps aside so the
    /// meeting can be read, and the toolbar offers a way back.
    private var searching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty && !viewingResult
    }

    private var hasQuery: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search every transcript")
        .onChange(of: search) { viewingResult = false }
        .toolbar { toolbar }
        .task(id: settings.folder(ConfigKey.destination)) {
            // Reloads on its own when the folder is changed in Settings.
            await automation.refresh()
        }
        // Menu commands live in the App scene and cannot reach this view's
        // state directly, so they raise a token the view acts on.
        .onChange(of: commands.refreshToken) { Task { await automation.refresh() } }
        .onChange(of: commands.chooseFolderToken) { chooseFolder() }
        .onChange(of: commands.request) { _, request in
            guard let request else { return }
            search = ""
            switch request.destination {
            case .meetings:
                // Never nil: that would drop the user on the empty state.
                if case .meeting = selection {} else {
                    selection = lastMeeting.map(Selection.meeting)
                        ?? library.folders.first.map(Selection.meeting)
                }
            case .actions:
                selection = .actions
            case .queue:
                selection = .queue
            }
        }
        .onChange(of: selection) { _, new in
            if case .meeting(let folder) = new {
                // Remembered so Cmd-1 can come back to where you were.
                lastMeeting = folder
                // Clicking a meeting while a search is open should show it, not
                // leave the results up.
                if hasQuery { viewingResult = true }
            }
        }
        .onChange(of: pipeline.lastCompletion) { _, completion in
            // A notes run can rename "Meeting 1" to its real title. The folder
            // the selection points at is then gone, so the new one is picked up
            // once the library has been read again.
            guard let completion, case .meeting(let folder) = selection,
                let renamed = completion.renamed[folder.id]
            else { return }
            followRename = Completions.canonicalPath(renamed)
        }
        .onChange(of: library.folders) {
            guard let target = followRename,
                let match = library.folders.first(where: {
                    Completions.canonicalPath($0.id) == target
                })
            else { return }
            followRename = nil
            selection = .meeting(match)
        }
        .alert("Group meetings by…", isPresented: $addingGrouping) {
            TextField("Company, Project, Client…", text: $newGrouping)
            Button("Add") { addGrouping() }
            Button("Cancel", role: .cancel) { newGrouping = "" }
        } message: {
            Text(
                "Each meeting gets one value for it, set in the bar above its notes. "
                    + "New meetings are filled in automatically when they are categorised."
            )
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if searching {
            SearchResultsView(query: search, limitedTo: taggedFolders) { folder, seconds in
                open(folder: folder, seek: seconds)
            }
        } else {
            switch selection {
            case .meeting(let folder):
                MeetingDetailView(
                    folder: folder,
                    library: library,
                    // Consumed by the opening it belongs to. Left set, it
                    // hijacked the next meeting opened by any other route,
                    // forcing the Transcript tab and an unrelated timestamp.
                    seekOnOpen: seekTarget == folder.id ? pendingSeek : nil
                )
                // Without this the detail view keeps the previously selected
                // meeting's @State when the selection changes.
                .id(folder.id)
            case .actions:
                ActionItemsView { folder in open(folder: folder, seek: nil) }
            case .queue:
                WatchQueueView()
            case nil:
                ContentUnavailableView(
                    "No meeting selected",
                    systemImage: "waveform",
                    description: Text("Pick a meeting, or search across every transcript.")
                )
            }
        }
    }

    private func open(folder: URL, seek: Double?) {
        guard let match = library.folders.first(where: { $0.id == folder }) else { return }
        pendingSeek = seek
        seekTarget = seek == nil ? nil : folder
        viewingResult = true
        selection = .meeting(match)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        switch library.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Nothing to show", systemImage: "folder.badge.questionmark")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Folder…") { chooseFolder() }
            }
        case .needsAccess(let url):
            // Choosing the folder in an open panel is what grants access, so
            // the button is the fix rather than a retry.
            ContentUnavailableView {
                Label("Cannot read that folder", systemImage: "lock")
            } description: {
                Text(
                    "\(url.path(percentEncoded: false))\n\nmacOS is blocking this app from "
                        + "reading it. Choosing the folder below grants access. Granting Transcribe "
                        + "Full Disk Access in System Settings > Privacy & Security also works."
                )
            } actions: {
                Button("Choose Folder…") { chooseFolder() }
                Button("Open Privacy Settings") {
                    if let settingsURL = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                    ) {
                        NSWorkspace.shared.open(settingsURL)
                    }
                }
            }
        case .loaded:
            VStack(spacing: 0) {
                List(selection: $selection) {
                    if !hasQuery {
                        Section {
                            Label("Action Items", systemImage: "checklist")
                                .badge(outstandingActions)
                                .tag(Selection.actions)
                            Label("Recording Queue", systemImage: "tray.full")
                                .badge(queue.pending.count)
                                .tag(Selection.queue)
                        }
                    } else {
                        Section {
                            Text(
                                filtered.isEmpty
                                    ? "No meetings mention that"
                                    : "\(filtered.count) meeting(s) mention that"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(groups, id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.value) { folder in
                                MeetingRow(folder: folder)
                                    .tag(Selection.meeting(folder))
                                    .contextMenu { rowMenu(for: folder) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                // A run started from the sidebar's context menu or the category
                // menu reports nowhere else unless a meeting or the queue
                // happens to be open.
                if pipeline.state != .idle, !isDetailShowingPipeline {
                    PipelineStatusBar()
                }
                RecordingStatusBar()
                statusFooter
            }
        }
    }

    /// Only what is still to do. The count of every action ever written grew
    /// without end and said nothing.
    private var outstandingActions: Int {
        index.allActions.filter {
            !completions.isDone(meeting: $0.meeting.folder, action: $0.action)
        }.count
    }

    /// True when the detail pane is already showing the pipeline's state, so
    /// the sidebar does not show it twice.
    private var isDetailShowingPipeline: Bool {
        if searching { return false }
        switch selection {
        case .meeting, .queue: return true
        default: return false
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        // The list is drawn from folder names alone; the files behind each one
        // and the transcript index both arrive after.
        if library.enriching || index.building {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(
                    index.building
                        ? "Indexing transcripts… \(Int(index.progress * 100))%"
                        : "Reading folders…"
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// The folders the category filter allows, or nil when it is off. Search
    /// used to ignore it, so filtering to a category and then searching
    /// returned meetings from every other category.
    private var taggedFolders: Set<URL>? {
        guard let tagFilter else { return nil }
        return Set(
            library.folders.map(\.id).filter { folder in
                tags.tags(for: folder)
                    .contains { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }
            })
    }

    private var filtered: [MeetingFolder] {
        // While searching, the sidebar narrows to the meetings the results are
        // drawn from. A full list beside a filtered detail pane reads as though
        // the search missed them.
        let matches: Set<URL>? =
            hasQuery ? Set(index.search(search).map(\.folder)) : nil

        return library.folders.filter { folder in
            if let matches, !matches.contains(folder.id) { return false }
            guard let tagFilter else { return true }
            return tags.tags(for: folder.id)
                .contains { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }
        }
    }

    private var groups: [(key: String, value: [MeetingFolder])] {
        LibraryGrouping.groups(
            filtered, by: grouping,
            categories: { tags.tags(for: $0) },
            field: { name, folder in tags.value(of: name, for: folder) })
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if viewingResult, hasQuery {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewingResult = false
                } label: {
                    Label("Back to Results", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .help("Return to the results for “\(search)”")
            }
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Group By", selection: $groupingID) {
                    Text("Month").tag(LibraryGrouping.month.id)
                    Text("Category").tag(LibraryGrouping.category.id)
                    ForEach(groupFields, id: \.self) { field in
                        Text(field).tag(LibraryGrouping.field(field).id)
                    }
                }
                .pickerStyle(.inline)
                Button("New Grouping…") { addingGrouping = true }

                Divider()

                Picker("Show", selection: $tagFilter) {
                    Text("All Meetings").tag(String?.none)
                    ForEach(tags.allTags, id: \.self) { tag in
                        Text(tag).tag(String?.some(tag))
                    }
                }
                .pickerStyle(.inline)

                Divider()
                Button("Categorise \(untagged.count) Uncategorised…") { categoriseUntagged() }
                    .disabled(untagged.isEmpty)
            } label: {
                Label(
                    tagFilter.map { "\(grouping.label): \($0)" } ?? "By \(grouping.label)",
                    systemImage: tagFilter == nil
                        ? "square.stack.3d.up" : "line.3.horizontal.decrease.circle.fill"
                )
                .labelStyle(.titleAndIcon)
            }
            .help("Group the meetings by month, category or your own fields, or show one category")
        }
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await automation.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan the meetings folder for new or changed meetings (⌘R)")
        }
    }

    /// Right-click actions. Everything here is also reachable from the
    /// toolbar or the detail view; a context menu is where a macOS user looks
    /// first for something that acts on one row.
    @ViewBuilder
    private func rowMenu(for folder: MeetingFolder) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([folder.id])
        }
        Divider()
        Button("Write Notes from Transcript") {
            pipeline.notesFromTranscript(folder: folder.id)
        }
        .disabled(pipeline.has(.notes(folder.id)))
        Button(tags.tags(for: folder.id).isEmpty ? "Categorise" : "Re-categorise") {
            pipeline.categorise(
                folders: [folder.id],
                // Without this the CLI skips a meeting that already has
                // categories, and the run reports success having changed
                // nothing.
                overwrite: !tags.tags(for: folder.id).isEmpty
            )
        }
        Divider()
        Menu("Category") {
            ForEach(tags.allTags, id: \.self) { tag in
                Button {
                    Task { try? await tags.toggle(tag, for: folder.id) }
                } label: {
                    if tags.tags(for: folder.id).contains(where: {
                        $0.caseInsensitiveCompare(tag) == .orderedSame
                    }) {
                        Label(tag, systemImage: "checkmark")
                    } else {
                        Text(tag)
                    }
                }
            }
            if tags.allTags.isEmpty {
                Text("No categories yet").foregroundStyle(.secondary)
            }
        }
        ForEach(groupFields, id: \.self) { field in
            Menu(field) {
                ForEach(tags.values(of: field), id: \.self) { value in
                    Button {
                        Task { try? await tags.set(field: field, to: value, for: folder.id) }
                    } label: {
                        if tags.value(of: field, for: folder.id) == value {
                            Label(value, systemImage: "checkmark")
                        } else {
                            Text(value)
                        }
                    }
                }
                if tags.values(of: field).isEmpty {
                    Text("Set one from the bar above the notes").foregroundStyle(.secondary)
                }
                if tags.value(of: field, for: folder.id) != nil {
                    Divider()
                    Button("Clear \(field)") {
                        Task { try? await tags.set(field: field, to: nil, for: folder.id) }
                    }
                }
            }
        }
    }

    private var untagged: [URL] {
        library.folders.map(\.id).filter { tags.tags(for: $0).isEmpty }
    }

    private func categoriseUntagged() {
        pipeline.categorise(folders: untagged)
    }

    private func addGrouping() {
        let name = newGrouping.trimmingCharacters(in: .whitespaces)
        newGrouping = ""
        guard !name.isEmpty else { return }
        if !groupFields.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            settings.setList(ConfigKey.groupFields, groupFields + [name])
        }
        groupingID = LibraryGrouping.field(name).id
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Pick the folder your meetings are saved to."
        panel.directoryURL = settings.folder(ConfigKey.destination)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Picking it in the panel IS the grant, so a previously blocked root
        // deserves another attempt.
        library.forget(root: url)
        selection = nil
        // Writing it through is what makes .task(id:) reload, and what the CLI
        // will read on its next run.
        settings.setFolder(ConfigKey.destination, url)
    }
}

private struct MeetingRow: View {
    @Environment(TagIndex.self) private var tags
    @Environment(MeetingIndex.self) private var index
    let folder: MeetingFolder

    /// A folder still called "Meeting 1" shows the title its notes gave it.
    private var title: String {
        guard folder.hasPlaceholderName, let entry = index.entry(for: folder.id),
            !MeetingFolder.isPlaceholderTitle(entry.title), entry.title != "Untitled meeting"
        else { return folder.displayName }
        return entry.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let date = folder.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                // Only once the folder has been listed is this known, so the
                // badge appears with the second pass rather than guessing.
                if folder.contents?.isLegacy == true {
                    Text("transcript only")
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help(
                            "Saved before this pipeline wrote structured notes. "
                                + "The transcript and summary are here; speakers, timestamps "
                                + "and notes are not. Write Notes rebuilds them."
                        )
                } else if index.entry(for: folder.id)?.hasNotes == false {
                    Text("no notes yet")
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("There is a transcript but no notes. Open the meeting to write them.")
                }
                ForEach(tags.tags(for: folder.id).prefix(2), id: \.self) { tag in
                    Text(tag)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
