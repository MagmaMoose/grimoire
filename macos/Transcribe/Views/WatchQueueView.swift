import SwiftUI

/// What is sitting in the watch folder, and whether it became a meeting.
///
/// Without this the pipeline is a black box. A recording either turns into
/// notes or it does not, and when it does not there is nowhere to look.
struct WatchQueueView: View {
    @Environment(WatchQueue.self) private var queue
    @Environment(Pipeline.self) private var pipeline
    @Environment(Settings.self) private var settings
    @Environment(Automation.self) private var automation

    private var automatic: Bool { settings.config.bool(ConfigKey.autoProcess, default: true) }
    private var processed: [PendingRecording] { queue.recordings.filter(\.isProcessed) }

    var body: some View {
        VStack(spacing: 0) {
            if pipeline.state != .idle || !pipeline.queued.isEmpty {
                PipelineStatusBar()
                Divider()
            }
            AutomationBanner()
            Divider()

            if queue.scanning && queue.recordings.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        if queue.pending.isEmpty {
                            Text(
                                queue.message
                                    ?? "Nothing waiting. New recordings in the watch folder appear here."
                            )
                            .foregroundStyle(.secondary)
                        }
                        ForEach(queue.pending) { RecordingRow(recording: $0) }
                    } header: {
                        Text("Waiting")
                    }

                    if !processed.isEmpty {
                        Section {
                            ForEach(processed) { RecordingRow(recording: $0) }
                        } header: {
                            HStack {
                                Text("Processed, but still in the watch folder")
                                Spacer()
                                Button("Move to Meeting Folders") { pipeline.tidy() }
                                    .disabled(pipeline.has(.tidy))
                                    .help(
                                        "Move each recording into the folder of the meeting it became, "
                                            + "as a finished run would have"
                                    )
                            }
                        }
                    }

                    VoiceMemosSection()
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Recording queue")
        .navigationSubtitle(
            queue.pending.isEmpty
                ? "Everything processed"
                : "\(queue.pending.count) waiting"
        )
        .toolbar {
            ToolbarItem {
                Button {
                    if let watch = settings.folder(ConfigKey.watch) {
                        NSWorkspace.shared.open(watch)
                    }
                } label: {
                    Label("Open Watch Folder", systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(settings.folder(ConfigKey.watch) == nil)
                .help("Open the folder new recordings are picked up from")
            }
        }
    }
}

/// Says whether recordings are processed without being asked, and switches it.
private struct AutomationBanner: View {
    @Environment(Settings.self) private var settings

    private var automatic: Bool { settings.config.bool(ConfigKey.autoProcess, default: true) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: automatic ? "bolt.circle.fill" : "bolt.slash.circle")
                .font(.title2)
                .foregroundStyle(automatic ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(automatic ? "Processing new recordings automatically" : "Automatic processing is off")
                    .fontWeight(.medium)
                Text(
                    automatic
                        ? "A recording is picked up once it has stopped growing for 30 seconds, and filed with its notes."
                        : "Recordings wait here until you process them."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Automatic", isOn: settings.flag(ConfigKey.autoProcess, default: true))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(automatic ? "Stop processing recordings automatically" : "Process recordings as they arrive")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }
}

private struct RecordingRow: View {
    @Environment(Pipeline.self) private var pipeline
    @Environment(Automation.self) private var automation
    let recording: PendingRecording

    private var job: Pipeline.Job? { pipeline.job(for: recording.url) }
    private var failed: Bool { automation.failures[recording.url] != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(recording.sizeText)
                    if let modified = recording.modified {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                    }
                    if recording.isProcessed {
                        Text("\(recording.processedInto.count) meeting(s)")
                    } else if let status = automation.status(of: recording) {
                        Text(status)
                            .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if job == nil {
                Button(buttonTitle) {
                    if failed {
                        automation.retry(recording.url)
                    } else {
                        pipeline.process(recording.url)
                    }
                }
                .help(
                    recording.isProcessed
                        ? "Run the pipeline over this recording again"
                        : "Transcribe this recording and write its notes now"
                )
            } else if pipeline.current?.id == job?.id {
                ProgressView().controlSize(.small)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Show in Finder")
            .help("Show this file in Finder")
        }
        .padding(.vertical, 3)
    }

    private var buttonTitle: String {
        if recording.isProcessed { return "Reprocess" }
        return failed ? "Retry" : "Process Now"
    }

    @ViewBuilder
    private var icon: some View {
        if recording.isProcessed {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if job != nil {
            Image(systemName: "gearshape.2").foregroundStyle(.tint)
        } else {
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }
}

/// Voice Memos, which arrive from the Voice Memos library rather than the
/// watch folder.
private struct VoiceMemosSection: View {
    @Environment(Settings.self) private var settings
    @Environment(Pipeline.self) private var pipeline
    @Environment(Automation.self) private var automation

    private var enabled: Bool { settings.config.bool(ConfigKey.voiceMemos, default: true) }

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "waveform.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        enabled
                            ? "New memos become meetings automatically, checked every 10 minutes."
                            : "Automatic import is off."
                    )
                    if let blocked = automation.voiceMemosBlocked {
                        Text(blocked).font(.caption).foregroundStyle(.orange)
                    } else if !Automation.voiceMemosLibraryExists {
                        Text("Voice Memos has not been used on this Mac yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Each memo is imported once, from a copy, so it stays in Voice Memos.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if automation.voiceMemosBlocked != nil {
                    Button("Open Privacy Settings") { automation.openFullDiskAccessSettings() }
                }
                Button("Import Now") { automation.importVoiceMemosNow() }
                    .disabled(pipeline.has(.voiceMemos))
                    .help("Import memos from the last few days that are not meetings yet")
            }
            .padding(.vertical, 3)
        } header: {
            Text("Voice Memos")
        }
    }
}

/// Shared progress strip for anything the CLI is doing.
struct PipelineStatusBar: View {
    @Environment(Pipeline.self) private var pipeline
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                switch pipeline.state {
                case .idle:
                    EmptyView()
                case .running(let label):
                    ProgressView().controlSize(.small)
                    Text("\(label)…").font(.callout)
                case .finished(let label):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(label) finished.").font(.callout)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).lineLimit(2)
                }
                if !pipeline.queued.isEmpty {
                    Text("\(pipeline.queued.count) more waiting")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .running = pipeline.state {
                    Button("Cancel") { pipeline.cancel() }
                        .help("Stop this run. Anything waiting starts next.")
                }
                if !pipeline.queued.isEmpty {
                    Button("Clear Queue") { pipeline.clearQueue() }
                        .help("Drop the runs that have not started")
                }
                if !pipeline.output.isEmpty {
                    Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }
                }
            }
            if showLog, !pipeline.output.isEmpty {
                ScrollView {
                    Text(pipeline.output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }
}

/// What the Notes export is doing.
struct AppleExportBar: View {
    @Environment(AppleExport.self) private var export

    var body: some View {
        HStack(spacing: 8) {
            switch export.status {
            case .idle:
                EmptyView()
            case .working(let label):
                ProgressView().controlSize(.small)
                Text("\(label)…").font(.callout)
            case .done(let message):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).font(.callout)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
            }
            Spacer()
            if export.status != .idle, !export.isWorking {
                Button("Dismiss") { export.clear() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }
}

/// What the last Reminders sync did, where the send was started from.
struct RemindersStatusBar: View {
    @Environment(RemindersSync.self) private var reminders

    var body: some View {
        HStack(spacing: 8) {
            switch reminders.status {
            case .idle:
                EmptyView()
            case .working(let label):
                ProgressView().controlSize(.small)
                Text("\(label)…").font(.callout)
            case .done(let message):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).font(.callout)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
            }
            Spacer()
            if case .done = reminders.status {
                Button("Open Reminders") { reminders.openReminders() }
            }
            if !reminders.isWorking {
                Button("Dismiss") { reminders.clear() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }
}

/// Recording state, in the main window.
///
/// It only ever showed in the menu bar, where a detected meeting, a recording,
/// and an OBS that refused to start all looked like a slightly different
/// circle. From here "auto-record does not work" was indistinguishable from
/// "auto-record is waiting".
struct RecordingStatusBar: View {
    @Environment(RecordingMonitor.self) private var monitor

    var body: some View {
        switch monitor.status {
        case .recording:
            bar {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text("Recording").font(.callout)
                Spacer()
                Button("Stop") { Task { await monitor.setRecording(false) } }
            }
        case .detected:
            bar {
                Image(systemName: "record.circle").foregroundStyle(.orange)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let seconds = monitor.waitingSeconds(now: context.date) {
                        Text("Meeting detected. Recording in \(seconds)s").font(.callout)
                    } else {
                        Text("Meeting detected").font(.callout)
                    }
                }
                Spacer()
                Button("Not This One") { monitor.skipCurrentMeeting() }
                    .help("Do not record until this meeting ends")
            }
        default:
            if let error = monitor.lastError {
                bar {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).lineLimit(2)
                    Spacer()
                    SettingsLink { Text("Settings…") }
                }
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4))
    }
}
