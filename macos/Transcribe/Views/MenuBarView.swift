import SwiftUI

/// The menu bar item: what the detector can see, and a manual override.
///
/// Automatic detection is a guess and always will be. It cannot see a meeting
/// you join with the camera and microphone off, and it occasionally reads
/// something else as a meeting. So the menu carries the two things detection
/// cannot provide: an override that always wins, and the raw signals, so a
/// wrong guess can be understood rather than just endured.
struct MenuBarView: View {
    @Environment(RecordingMonitor.self) private var monitor
    @Environment(Pipeline.self) private var pipeline
    @Environment(WatchQueue.self) private var queue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(monitor.status.label)

            Text("Signals: \(monitor.presence.describe)")
                .font(.caption)

            if let seconds = monitor.waitingSeconds() {
                Text("Recording starts in \(seconds)s").font(.caption)
            }
            if let error = monitor.lastError {
                Text(error).font(.caption)
            }
            if let error = pipeline.recordError {
                Text(error).font(.caption)
                Button("Dismiss") { pipeline.clearRecordError() }
            }

            Divider()

            if monitor.status == .recording {
                Button("Stop Recording") { Task { await monitor.setRecording(false) } }
            } else {
                Button("Record Now") { Task { await monitor.setRecording(true) } }
            }

            Toggle("Pause Auto-Record", isOn: pausedBinding)

            Divider()

            if !queue.pending.isEmpty {
                Text("\(queue.pending.count) recording(s) not yet processed")
                    .font(.caption)
            }

            Button("Open Transcribe") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "library")
            }

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var pausedBinding: Binding<Bool> {
        Binding(get: { monitor.paused }, set: { monitor.paused = $0 })
    }

}
