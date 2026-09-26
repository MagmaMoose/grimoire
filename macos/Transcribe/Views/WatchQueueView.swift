import SwiftUI

/// What is sitting in the watch folder, and whether it became a meeting.
///
/// Without this the pipeline is a black box. A recording either turns into
/// notes or it does not, and when it does not there is nowhere to look.
struct WatchQueueView: View {
    @Environment(WatchQueue.self) private var queue
    @Environment(Pipeline.self) private var pipeline
    @Environment(Settings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            if pipeline.state != .idle {
                PipelineStatusBar()
                Divider()
            }

            if queue.scanning {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if queue.recordings.isEmpty {
                ContentUnavailableView {
                    Label("Nothing waiting", systemImage: "tray")
                } description: {
                    Text(
                        queue.message
                            ?? "Recordings dropped into the watch folder appear here."
                    )
                } actions: {
                    if let watch = settings.folder(ConfigKey.watch) {
                        Button("Open watch folder") { NSWorkspace.shared.open(watch) }
                    }
                }
            } else {
                List {
                    if !queue.pending.isEmpty {
                        Section("Not yet processed") {
                            ForEach(queue.pending) { RecordingRow(recording: $0) }
                        }
                    }
                    let done = queue.recordings.filter(\.isProcessed)
                    if !done.isEmpty {
                        Section("Already processed") {
                            ForEach(done) { RecordingRow(recording: $0) }
                        }
                    }
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
                    Label("Open Watch Folder", systemImage: "arrow.up.forward.app")
                }
                .disabled(settings.folder(ConfigKey.watch) == nil)
                .help("Open the folder new recordings are picked up from")
            }
        }
    }
}

private struct RecordingRow: View {
    @Environment(Pipeline.self) private var pipeline
    let recording: PendingRecording

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: recording.isProcessed ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(recording.isProcessed ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(recording.sizeText)
                    if let modified = recording.modified {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                    }
                    if recording.isProcessed {
                        Text("\(recording.processedInto.count) meeting(s)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button(recording.isProcessed ? "Reprocess" : "Process") {
                pipeline.process(recording.url)
            }
            .disabled(pipeline.isRunning)
            .help(
                recording.isProcessed
                    ? "Run the pipeline over this recording again"
                    : "Transcribe this recording and write its notes"
            )

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .accessibilityLabel("Show in Finder")
            .help("Show this file in Finder")
        }
        .padding(.vertical, 3)
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
                    Spacer()
                    Button("Cancel") { pipeline.cancel() }
                case .finished(let label):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(label) finished.").font(.callout)
                    Spacer()
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).lineLimit(2)
                    Spacer()
                }
                if !pipeline.output.isEmpty {
                    Button(showLog ? "Hide log" : "Show log") { showLog.toggle() }
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

/// What the Notes/Reminders export is doing.
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
