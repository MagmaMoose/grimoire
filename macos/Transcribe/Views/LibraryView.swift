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

    @State private var selection: Selection?
    @State private var search = ""
    @State private var tagFilter: String?
    /// Set when a search result is opened, so the meeting can jump straight to
    /// the line that matched.
    @State private var pendingSeek: Double?
    @State private var seekTarget: URL?
    @State private var lastMeeting: MeetingFolder?
    @State private var viewingResult = false

    /// What the detail pane is showing. A meeting is one case among several so
    /// the action list and the queue are first-class destinations rather than
    /// sheets bolted onto the side.
    enum Selection: Hashable {
        case meeting(MeetingFolder)
        case actions
        case queue
    }

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
            await refresh()
        }
        // Menu commands live in the App scene and cannot reach this view's
        // state directly, so they raise a token the view acts on.
        .onChange(of: commands.refreshToken) { Task { await refresh() } }
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
        .onChange(of: pipeline.state) { _, new in
            // A finished run has written new files; the library, tags and
            // index all describe the old ones until they are re-read.
            if case .finished = new { Task { await refresh() } }
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
                            Label("Action items", systemImage: "checklist")
                                .badge(index.allActions.count)
                                .tag(Selection.actions)
                            Label("Recording queue", systemImage: "tray.full")
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
                statusFooter
            }
        }
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

    /// Grouped by month, newest first. `folders` is already sorted, so the
    /// groups come out in order without a second sort.
    private var groups: [(key: String, value: [MeetingFolder])] {
        var order: [String] = []
        var buckets: [String: [MeetingFolder]] = [:]
        for folder in filtered {
            let key = folder.date.map {
                $0.formatted(.dateTime.month(.wide).year())
            } ?? "Undated"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(folder)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if viewingResult, hasQuery {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewingResult = false
                } label: {
                    Label("Back to results", systemImage: "chevron.left")
                }
                .help("Return to the results for “\(search)”")
            }
        }
        ToolbarItem {
            Menu {
                Button("All meetings") { tagFilter = nil }
                if !tags.allTags.isEmpty {
                    Divider()
                    ForEach(tags.allTags, id: \.self) { tag in
                        Button {
                            tagFilter = tag
                        } label: {
                            if tagFilter == tag {
                                Label(tag, systemImage: "checkmark")
                            } else {
                                Text(tag)
                            }
                        }
                    }
                }
                Divider()
                Button("Categorise \(untagged.count) uncategorised…") { categoriseUntagged() }
                    .disabled(pipeline.isRunning || untagged.isEmpty)
            } label: {
                Label(
                    tagFilter ?? "All categories",
                    systemImage: tagFilter == nil ? "tag" : "tag.fill"
                )
            }
            .help("Filter by category, or have the notes provider assign them")
        }
        ToolbarItem {
            Button {
                chooseFolder()
            } label: {
                Label("Change Meetings Folder", systemImage: "folder.badge.gearshape")
            }
            .help("Change which folder this app lists meetings from")
        }
        ToolbarItem {
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan the meetings folder for new or changed meetings")
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
        .disabled(pipeline.isRunning)
        Button(tags.tags(for: folder.id).isEmpty ? "Categorise" : "Re-categorise") {
            pipeline.categorise(
                folders: [folder.id],
                // Without this the CLI skips a meeting that already has
                // categories, and the run reports success having changed
                // nothing.
                overwrite: !tags.tags(for: folder.id).isEmpty
            )
        }
        .disabled(pipeline.isRunning)
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
    }

    private var untagged: [URL] {
        library.folders.map(\.id).filter { tags.tags(for: $0).isEmpty }
    }

    private func categoriseUntagged() {
        pipeline.categorise(folders: untagged)
    }

    private func refresh() async {
        await library.load(root: settings.folder(ConfigKey.destination))
        await tags.load(folders: library.folders)
        index.build(folders: library.folders)
        await queue.load(watch: settings.folder(ConfigKey.watch), library: library.folders)
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
    let folder: MeetingFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(folder.displayName)
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
                                + "and notes are not. Generate Notes rebuilds them."
                        )
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
