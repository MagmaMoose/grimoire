import Foundation
import SwiftUI

/// Runs the `transcribe` command line tool on behalf of the app.
///
/// The app deliberately does not reimplement any of the pipeline. Whisper,
/// diarization and the LLM calls all live in the Python, and this shells out to
/// exactly the command a user would type, so there is one implementation and
/// one set of settings behind both.
@MainActor
@Observable
final class Pipeline {
    enum State: Equatable {
        case idle
        case running(String)
        case finished(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var output: String = ""
    /// The meeting folder the current run is about, so a detail view can tell
    /// whether a finished run concerns it.
    private(set) var lastTarget: URL?

    /// Recording failures, kept apart from `state` so they cannot overwrite a
    /// transcription that is still running.
    private(set) var recordError: String?
    private(set) var recordOutput: String = ""

    func clearRecordError() { recordError = nil; recordOutput = "" }
    private var task: Task<Void, Never>?

    /// Holds the running child so cancelling can actually kill it.
    ///
    /// `@unchecked Sendable` behind a lock: it is set on the queue thread that
    /// launched the process and read from the main actor when cancelling.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func adopt(_ process: Process) {
            lock.lock(); self.process = process; lock.unlock()
        }

        func terminate() {
            lock.lock(); let running = process; lock.unlock()
            guard let running, running.isRunning else { return }
            running.terminate()
        }

        func release() { lock.lock(); process = nil; lock.unlock() }
    }

    private var box = ProcessBox()
    /// Distinguishes our own terminate from an external kill.
    private var wasCancelled = false

    /// Where the CLI might be. A Homebrew install and a local checkout put it
    /// in different places, and the app must not care which the user has.
    static func locate() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/transcribe",
            "/usr/local/bin/transcribe",
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".local/bin/transcribe").path(percentEncoded: false),
            "/opt/homebrew/bin/transcribe-dev",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    /// Stop the running command.
    ///
    /// Cancelling the Swift task is not enough: the `Process` runs whisper and
    /// LLM calls for minutes and knows nothing about task cancellation, so it
    /// carried on while the buttons re-enabled and a second run could be
    /// started over the same folder. The child is signalled too.
    func cancel() {
        if isRunning { wasCancelled = true }
        box.terminate()
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Reprocess one meeting folder's recording, which regenerates its notes.
    func regenerate(folder: MeetingFolder, media: URL?, label: String) {
        guard let tool = Self.locate() else {
            state = .failed(missingToolMessage)
            return
        }
        guard let media else {
            state = .failed("This meeting has no recording to reprocess.")
            return
        }
        // --keep-source, or the run moves this meeting's own recording out of
        // the folder being reprocessed and into whichever new folder it
        // produces, leaving a duplicate meeting and a folder with no media.
        run(
            tool: tool,
            arguments: [media.path(percentEncoded: false), "--keep-source"],
            label: label,
            target: folder.id
        )
    }

    /// Write notes from the transcript a folder already has.
    ///
    /// The cheap path, and the right default. Re-transcribing an hour of audio
    /// to produce notes from words the folder already contains is wasteful, and
    /// for older meetings the audio may not even be there any more.
    func notesFromTranscript(folder: URL) {
        guard let tool = Self.locate() else {
            state = .failed(missingToolMessage)
            return
        }
        run(
            tool: tool,
            arguments: ["notes", folder.path(percentEncoded: false)],
            label: "Writing notes from the transcript",
            target: folder
        )
    }

    /// Process one recording from the watch folder.
    func process(_ url: URL) {
        guard let tool = Self.locate() else {
            state = .failed(missingToolMessage)
            return
        }
        // A watch-folder recording is meant to be filed, so the source moves.
        run(
            tool: tool,
            arguments: [url.path(percentEncoded: false)],
            label: "Processing \(url.lastPathComponent)"
        )
    }

    /// Ask the CLI to categorise meetings using the configured LLM.
    ///
    /// The provider, key, model and prompt all live in the Python already;
    /// re-implementing an LLM client here would be a second thing to configure
    /// and a second thing to get wrong.
    func categorise(folders: [URL], overwrite: Bool = false) {
        guard let tool = Self.locate() else {
            state = .failed(missingToolMessage)
            return
        }
        guard !folders.isEmpty else { return }
        var arguments = ["categorise"] + folders.map { $0.path(percentEncoded: false) }
        if overwrite { arguments.append("--overwrite") }
        run(
            tool: tool,
            arguments: arguments,
            label: folders.count == 1
                ? "Categorising 1 meeting" : "Categorising \(folders.count) meetings",
            target: folders.count == 1 ? folders[0] : nil
        )
    }

    /// Start or stop an OBS recording via the CLI, which already speaks
    /// obs-websocket.
    ///
    /// Awaited and returning success, so the caller does not claim a recording
    /// started when OBS refused. This deliberately does not go through `run`:
    /// it must not clobber the state of a long transcription that is running.
    @discardableResult
    func controlRecording(start: Bool) async -> Bool {
        guard let tool = Self.locate() else {
            state = .failed(missingToolMessage)
            return false
        }
        let result = await Self.execute(
            tool: tool,
            arguments: ["record", start ? "start" : "stop"],
            box: ProcessBox()
        )
        if result.status != 0 {
            // Reported separately, not through `state`: a transcription can be
            // running, and overwriting its state hides the Cancel button and
            // re-enables the controls that would kill it.
            recordError =
                (start ? "Could not start recording" : "Could not stop recording")
                + " (exit \(result.status))."
            recordOutput = result.output
        } else {
            recordError = nil
            recordOutput = ""
        }
        return result.status == 0
    }

    private var missingToolMessage: String {
        "The transcribe command line tool was not found. Install it with "
            + "'brew install calebsargeant/tap/transcribe'."
    }

    private func run(tool: URL, arguments: [String], label: String, target: URL? = nil) {
        cancel()
        lastTarget = target
        state = .running(label)
        output = ""

        let box = ProcessBox()
        self.box = box
        task = Task { [weak self] in
            let result = await Self.execute(tool: tool, arguments: arguments, box: box)
            box.release()
            guard let self, !Task.isCancelled else { return }
            self.output = result.output
            switch result.status {
            case 0:
                self.state = .finished(label)
            case let status where status < 0:
                // Process reports a signal as a negative status. Anything
                // signalled while we were not cancelling was killed from
                // outside, which is worth saying rather than calling it a
                // generic failure.
                self.state =
                    self.wasCancelled
                    ? .idle
                    : .failed("\(label) was stopped (signal \(-status)).")
            default:
                self.state = .failed(
                    "\(label) failed (exit \(result.status)). See the log below.")
            }
            self.wasCancelled = false
        }
    }

    /// Runs the tool and collects its output.
    ///
    /// Reading both pipes concurrently matters: the pipeline is chatty, and a
    /// child that fills the pipe buffer while the parent waits on `exit` is a
    /// deadlock rather than a slow run.
    private nonisolated static func execute(
        tool: URL, arguments: [String], box: ProcessBox
    ) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                // A GUI app inherits a bare PATH; the pipeline shells out to
                // ffmpeg and whisper, which live where Homebrew put them.
                var environment = ProcessInfo.processInfo.environment
                let path = environment["PATH"] ?? "/usr/bin:/bin"
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
                process.environment = environment

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                box.adopt(process)
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "Could not start: \(error.localizedDescription)"))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: (
                        process.terminationStatus,
                        String(data: data, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }
}
