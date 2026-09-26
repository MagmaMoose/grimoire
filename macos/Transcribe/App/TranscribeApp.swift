import SwiftUI

/// Holds the app open long enough to finish writing settings.
///
/// The settings store debounces writes by 400ms and the app declares
/// `NSSupportsAutomaticTermination`, so quitting just after typing an API key
/// dropped it with no warning at all.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var settings: Settings?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let settings, settings.hasUnsavedEdits else { return .terminateNow }
        Task { @MainActor in
            await settings.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // One store each, shared by every window and the menu bar, so nothing can
    // disagree about where the meetings are or what is in them.
    @State private var settings: Settings
    @State private var monitor: RecordingMonitor
    @State private var tags: TagIndex
    @State private var index: MeetingIndex
    @State private var pipeline: Pipeline
    @State private var queue: WatchQueue
    @State private var completions: Completions
    @State private var appleExport: AppleExport
    @State private var reminders: RemindersSync
    @State private var library: MeetingLibrary
    @State private var automation: Automation
    @State private var commands = AppCommands()

    init() {
        // A toolbar of icons is only as clear as its tooltips, and the system
        // waits well over a second before showing one. Registered, not set, so
        // a delay the user chose with `defaults write` still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 350])

        // Built here rather than as separate defaults: several need each
        // other, and the monitor and the automation have to start with the app,
        // not with a window. Started from the window's first appearance, auto-
        // record and the queue did nothing when the app launched to the menu
        // bar alone.
        let settings = Settings()
        let monitor = RecordingMonitor(settings: settings)
        let tags = TagIndex()
        let index = MeetingIndex()
        let pipeline = Pipeline()
        let queue = WatchQueue()
        let completions = Completions()
        let appleExport = AppleExport()
        let reminders = RemindersSync(export: appleExport)
        let library = MeetingLibrary()
        let automation = Automation(
            settings: settings, library: library, tags: tags, index: index, queue: queue,
            pipeline: pipeline, completions: completions, reminders: reminders, monitor: monitor)

        _settings = State(initialValue: settings)
        _monitor = State(initialValue: monitor)
        _tags = State(initialValue: tags)
        _index = State(initialValue: index)
        _pipeline = State(initialValue: pipeline)
        _queue = State(initialValue: queue)
        _completions = State(initialValue: completions)
        _appleExport = State(initialValue: appleExport)
        _reminders = State(initialValue: reminders)
        _library = State(initialValue: library)
        _automation = State(initialValue: automation)

        monitor.control = { [weak monitor] start in
            await monitor?.driveOBS(start: start) ?? false
        }
        monitor.start()
        automation.start()
    }

    var body: some Scene {
        WindowGroup(id: "library") {
            LibraryView()
                .frame(minWidth: 900, minHeight: 560)
                .environment(settings)
                .environment(tags)
                .environment(index)
                .environment(pipeline)
                .environment(queue)
                .environment(monitor)
                .environment(completions)
                .environment(appleExport)
                .environment(reminders)
                .environment(library)
                .environment(commands)
                .environment(automation)
                .task { delegate.settings = settings }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Change Meetings Folder…") { commands.chooseFolder() }
                Button("Open Meetings Folder") {
                    if let url = settings.folder(ConfigKey.destination) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Open Watch Folder") {
                    if let url = settings.folder(ConfigKey.watch) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Import New Voice Memos") { automation.importVoiceMemosNow() }
                Button("Write Missing Notes") {
                    automation.writeNotes(for: automation.meetingsMissingNotes)
                }
                .disabled(automation.meetingsMissingNotes.isEmpty)
                Button("Move Processed Recordings Out of the Watch Folder") { pipeline.tidy() }
            }

            // A native app is keyboard-drivable. Without these the only way to
            // reach anything is the mouse.
            CommandGroup(after: .toolbar) {
                Button("Meetings") { commands.show(.meetings) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Action Items") { commands.show(.actions) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Recording Queue") { commands.show(.queue) }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Refresh") { commands.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(replacing: .help) {
                DiagnosticsCommand()
                Button("Transcribe on GitHub") {
                    if let url = URL(string: "https://github.com/CalebSargeant/transcribe") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
        }
        .defaultSize(width: 680, height: 560)

        MenuBarExtra {
            MenuBarView()
                .environment(settings)
                .environment(pipeline)
                .environment(queue)
                .environment(monitor)
        } label: {
            Image(systemName: monitor.status.symbol)
        }

        SwiftUI.Settings {
            SettingsView()
                .environment(settings)
                .environment(appleExport)
                .environment(reminders)
                .environment(automation)
                // Closing the window is the other moment an edit can be
                // stranded in the debounce.
                .onDisappear { Task { await settings.flush() } }
        }
        // Each tab asks for the height it needs; this lets the window be made
        // taller still rather than fixing it at that.
        .windowResizability(.contentMinSize)
    }
}

/// Help ▸ Run Diagnostics. A view of its own because `openWindow` is only
/// available from the environment.
private struct DiagnosticsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Run Diagnostics…") { openWindow(id: "diagnostics") }
    }
}
