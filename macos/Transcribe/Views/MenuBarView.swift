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
    @Environment(Settings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    private var automatic: Bool { settings.config.bool(ConfigKey.autoRecord, default: true) }

    var body: some View {
        Group {
            Text(automatic ? monitor.status.label : "Automatic recording is off")

            Text("Signals: \(monitor.presence.describe)")
                .font(.caption)

            if let seconds = monitor.waitingSeconds() {
                Text("Recording starts in \(seconds)s").font(.caption)
            }
            if let error = monitor.lastError {
                Text(error).font(.caption)
                Button("Dismiss") { monitor.clearError() }
            }
            if let error = pipeline.recordError {
                Text(error).font(.caption)
                Button("Dismiss") { pipeline.clearRecordError() }
            }
            // Without calendar access a camera-off meeting is never detected,
            // and nothing said so.
            if automatic, settings.config.bool(ConfigKey.useCalendar, default: true),
                !Presence.calendarAuthorised
            {
                Button("Allow Calendar Access…") {
                    Task {
                        NSApp.activate(ignoringOtherApps: true)
                        _ = await Presence.requestCalendarAccess()
                    }
                }
            }

            Divider()

            if monitor.status == .recording {
                Button("Stop Recording") { Task { await monitor.setRecording(false) } }
            } else {
                Button("Record Now") { Task { await monitor.setRecording(true) } }
            }
            if monitor.status == .detected {
                Button("Don't Record This Meeting") { monitor.skipCurrentMeeting() }
            }

            Toggle("Pause Auto-Record", isOn: pausedBinding)
                .disabled(!automatic)

            Divider()

            switch pipeline.state {
            case .running(let label):
                Text("\(label)…").font(.caption)
            case .failed(let message):
                Text(message).font(.caption)
            default:
                EmptyView()
            }
            if !pipeline.queued.isEmpty {
                Text("\(pipeline.queued.count) more waiting").font(.caption)
            }
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
