import SwiftUI

/// One meeting: its notes, its transcript, and the recording they came from.
struct MeetingDetailView: View {
    let folder: MeetingFolder
    let library: MeetingLibrary
    /// A point in the recording to jump to once it is ready, set when the
    /// meeting was opened from a search result.
    var seekOnOpen: Double?

    @Environment(TagIndex.self) private var tags
    @Environment(Pipeline.self) private var pipeline
    @Environment(AppleExport.self) private var appleExport
    @Environment(RemindersSync.self) private var reminders
    @Environment(Automation.self) private var automation
    @Environment(Settings.self) private var settings
    @State private var contents: MeetingFolder.Contents?
    @State private var record: MeetingRecord?
    @State private var legacyTranscript: String?
    @State private var legacySummary: String?
    @State private var loadError: String?
    @State private var loading = true
    @State private var tab: Tab = .notes
    @State private var playback = PlaybackController()
    @State private var showPlayer = true
    @State private var openedMedia: URL?

    private enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle(record?.displayTitle ?? folder.displayName)
        .navigationSubtitle(subtitle)
        .toolbar {
            // Every item carries its name as well as its icon. Icon-only, the
            // only way to learn what each did was to hover and wait for the
            // tooltip, one button at a time.
            if playableMedia != nil {
                ToolbarItem {
                    Toggle(isOn: $showPlayer) {
                        Label(
                            "Recording",
                            systemImage: playback.phase.kind == .audio
                                ? "waveform" : "play.rectangle"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    .help(showPlayer ? "Hide the recording" : "Show the recording")
                }
            }
            ToolbarItem {
                Menu {
                    Button {
                        pipeline.notesFromTranscript(folder: folder.id)
                    } label: {
                        Label("From the Transcript", systemImage: "text.alignleft")
                    }
                    .disabled(!hasTranscript || writingNotes)
                    .help("Fast: uses the transcript already saved, no re-transcribing")

                    Button {
                        pipeline.regenerate(
                            folder: folder, media: playableMedia,
                            label: "Re-transcribing \(folder.displayName)")
                    } label: {
                        Label("Re-transcribe the Recording", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(playableMedia == nil || reprocessing)
                    .help("Slow: transcribes the audio again, then writes notes")
                } label: {
                    Label(
                        record?.notes == nil ? "Write Notes" : "Rewrite Notes",
                        systemImage: "sparkles"
                    )
                    .labelStyle(.titleAndIcon)
                } primaryAction: {
                    // The common case, and the cheap one.
                    if hasTranscript {
                        pipeline.notesFromTranscript(folder: folder.id)
                    } else {
                        pipeline.regenerate(
                            folder: folder, media: playableMedia,
                            label: "Transcribing \(folder.displayName)")
                    }
                }
                .disabled(writingNotes || reprocessing || (!hasTranscript && playableMedia == nil))
                .help(
                    hasTranscript
                        ? "Write notes from the transcript this meeting already has"
                        : "Transcribe the recording, then write notes"
                )
            }
            ToolbarItem {
                Menu {
                    Button {
                        sendToNotes()
                    } label: {
                        Label("Send to Notes", systemImage: "note.text")
                    }
                    .disabled(record?.notes == nil || appleExport.isWorking)

                    Button {
                        Task { await automation.sendToReminders(meeting: folder.id) }
                    } label: {
                        Label(
                            actionItems.isEmpty
                                ? "No Action Items for Reminders"
                                : "Add \(actionItems.count) Action Item\(actionItems.count == 1 ? "" : "s") to Reminders",
                            systemImage: "checklist")
                    }
                    .disabled(actionItems.isEmpty || reminders.isWorking)

                    Divider()

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder.id])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .help("Send this meeting to Notes, its action items to Reminders, or show it in Finder")
            }
        }
        .task {
            await load()
        }
        .onChange(of: pipeline.lastCompletion) { _, completion in
            // The pipeline has just rewritten a folder. Without this the notes
            // it produced are invisible until you click away and back, which
            // makes the feature look broken when it worked. Only reload when
            // the run was about *this* meeting, or every open detail view
            // re-reads on any run. A folder the run renamed is followed by the
            // library instead, since this one no longer exists.
            guard let completion, completion.job.target == folder.id,
                completion.renamed.isEmpty
            else { return }
            Task { await load(refresh: true) }
        }
    }

    private var writingNotes: Bool { pipeline.has(.notes(folder.id)) }

    private var reprocessing: Bool {
        guard let media = playableMedia else { return false }
        return pipeline.has(.reprocess(media))
    }

    /// What the notes pane should offer when there are no notes.
    private var missingNotes: NotesPane.Missing {
        if writingNotes || reprocessing { return .writing }
        if !hasTranscript { return .noTranscript }
        return settings.hasLLMCredential ? .canWrite : .noProvider
    }

    /// The recording to play.
    ///
    /// Usually the file in the meeting folder. When `move_source_video` is off,
    /// or the recording already lived inside the destination, the pipeline
    /// leaves it where it was and the folder holds only notes -- but
    /// `source_file` still records where it went, so the video is findable
    /// rather than simply absent.
    private var playableMedia: URL? {
        if let media = contents?.media { return media }
        guard let source = record?.sourceFile else { return nil }
        let url = URL(filePath: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// True when the recording is not in this meeting's own folder.
    private var mediaIsElsewhere: Bool {
        contents?.media == nil && playableMedia != nil
    }

    private var hasTranscript: Bool {
        contents?.transcriptText != nil || record?.segments.isEmpty == false
    }

    private var actionItems: [IndexedMeeting.Action] {
        (record?.notes?.nextSteps ?? []).map {
            IndexedMeeting.Action(owner: $0.owner, title: $0.title, detail: $0.detail)
        }
    }

    private func sendToNotes() {
        guard let record else { return }
        let html = NoteBody.html(for: record, folder: folder.id, date: folder.date)
        let name = settings.config.string(ConfigKey.notesFolder, default: "Meetings")
        Task { await appleExport.sendToNotes(html: html, title: record.displayTitle, folder: name) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = folder.date {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if let seconds = record?.durationSeconds, let minutes = Timecode.minutes(from: seconds) {
            parts.append("\(minutes) min")
        }
        let people = record?.speakingParticipants.count ?? 0
        if people > 0 { parts.append("\(people) voice\(people == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        VSplitView {
            if showPlayer, let media = playableMedia {
                let pane = MediaPane(
                    playback: playback, media: media, isElsewhere: mediaIsElsewhere)
                if let height = pane.preferredHeight {
                    // Audio gets a bar, not a screen's worth of black.
                    pane.frame(height: height)
                } else {
                    pane.frame(minHeight: 200, idealHeight: 320)
                }
            }

            VStack(spacing: 0) {
                TagBar(folder: folder)
                if pipeline.state != .idle {
                    PipelineStatusBar()
                }
                if appleExport.status != .idle {
                    AppleExportBar()
                }
                if reminders.status != .idle {
                    RemindersStatusBar()
                }
                Divider()

                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 8)
                // A segmented control buried in the content has no keyboard
                // route; these give it one.
                .background {
                    HStack {
                        Button("") { tab = .notes }.keyboardShortcut("[", modifiers: .command)
                        Button("") { tab = .transcript }.keyboardShortcut("]", modifiers: .command)
                    }
                    .opacity(0)
                    .accessibilityHidden(true)
                }

                Divider()

                switch tab {
                case .notes:
                    NotesPane(
                        record: record,
                        legacySummary: legacySummary,
                        loadError: loadError,
                        missing: missingNotes,
                        onWrite: { pipeline.notesFromTranscript(folder: folder.id) },
                        onSeek: seek
                    )
                case .transcript:
                    TranscriptPane(
                        record: record,
                        legacyTranscript: legacyTranscript,
                        onSeek: seek
                    )
                }
            }
            .frame(minHeight: 240)
        }
    }

    private func seek(to second: Double) {
        guard playback.phase.isReady else { return }
        showPlayer = true
        playback.seek(
            toRecordingSecond: second,
            meetingStart: record?.clipOffset(forMedia: playableMedia) ?? 0
        )
    }

    /// Stamps each load so a slow one cannot publish over the results of a
    /// newer one -- which is exactly the refresh that follows a pipeline run.
    @State private var loadID = 0

    private func load(refresh: Bool = false) async {
        loadID += 1
        let id = loadID
        // A refresh keeps the current content on screen rather than flashing a
        // spinner over notes the user is reading.
        if !refresh { loading = true }
        defer { loading = false }

        // The background pass may not have reached this folder yet, so listing
        // it here is what keeps selection responsive.
        let contents = await library.contents(of: folder, refresh: refresh)
        guard id == loadID else { return }
        self.contents = contents
        if refresh {
            record = nil
            legacyTranscript = nil
            legacySummary = nil
            loadError = nil
        }

        do {
            let loaded = try await MeetingLibrary.loadRecord(contents.notesJSON)
            guard id == loadID else { return }
            record = loaded
        } catch {
            // A folder whose JSON will not parse still has its text files, so
            // the error is reported without giving up on the meeting.
            loadError = "notes.json could not be read: \(error.localizedDescription)"
        }

        if record == nil {
            let transcript = await MeetingLibrary.loadText(contents.transcriptText)
            let summary = await MeetingLibrary.loadText(contents.summaryText)
            guard id == loadID else { return }
            legacyTranscript = transcript
            legacySummary = summary
        }

        // Resolved after the record is read, since the fallback comes from it.
        // Reopening the same file would restart playback under the user, so it
        // only happens when the file actually changed.
        if playableMedia != openedMedia {
            openedMedia = playableMedia
            await playback.open(playableMedia)
        }

        // Only now is there a player to seek.
        if let seekOnOpen, !refresh {
            tab = .transcript
            seek(to: seekOnOpen)
        }
    }
}

/// The meeting's categories and grouping fields, editable inline.
private struct TagBar: View {
    @Environment(TagIndex.self) private var tags
    @Environment(Settings.self) private var settings
    let folder: MeetingFolder

    @State private var draft = ""
    @State private var adding = false
    /// The field a new value is being typed for, if any.
    @State private var editingField: String?
    @State private var error: String?

    private var current: [String] { tags.tags(for: folder.id) }
    private var fields: [String] { settings.list(ConfigKey.groupFields) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
                .help("Categories for this meeting")

            ForEach(current, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                    Button {
                        Task { await apply { try await tags.toggle(tag, for: folder.id) } }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(tag)")
                }
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: Capsule())
            }

            if adding || editingField != nil {
                TextField(editingField ?? "Category", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit(commit)
                Button("Add", action: commit).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { cancelEditing() }
            } else {
                Menu {
                    Button("New Category…") { adding = true }
                    // Offer what is already in use, so the same category is not
                    // retyped three different ways.
                    let unused = tags.allTags.filter { existing in
                        !current.contains { $0.caseInsensitiveCompare(existing) == .orderedSame }
                    }
                    if !unused.isEmpty {
                        Divider()
                        ForEach(unused, id: \.self) { tag in
                            Button(tag) {
                                Task { await apply { try await tags.toggle(tag, for: folder.id) } }
                            }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Categorise this meeting")

                ForEach(fields, id: \.self) { field in
                    fieldMenu(field)
                }
            }

            Spacer()

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// One grouping field: its value, the values other meetings use, and a way
    /// to type a new one.
    private func fieldMenu(_ field: String) -> some View {
        let value = tags.value(of: field, for: folder.id)
        return Menu {
            ForEach(tags.values(of: field), id: \.self) { option in
                Button {
                    Task { await apply { try await tags.set(field: field, to: option, for: folder.id) } }
                } label: {
                    if option == value {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
            if !tags.values(of: field).isEmpty { Divider() }
            Button("New \(field)…") { editingField = field }
            if value != nil {
                Button("Clear \(field)") {
                    Task { await apply { try await tags.set(field: field, to: nil, for: folder.id) } }
                }
            }
        } label: {
            Text(value.map { "\(field): \($0)" } ?? "\(field)…")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which \(field.lowercased()) this meeting belongs to, for grouping the sidebar")
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        let field = editingField
        cancelEditing()
        if let field {
            Task { await apply { try await tags.set(field: field, to: value, for: folder.id) } }
        } else {
            Task { await apply { try await tags.set(current + [value], for: folder.id) } }
        }
    }

    private func cancelEditing() {
        adding = false
        editingField = nil
        draft = ""
    }

    private func apply(_ change: () async throws -> Void) async {
        do {
            try await change()
            error = nil
        } catch {
            self.error = "Could not save categories"
        }
    }
}
