import Foundation
import SwiftUI

/// Runs the `transcribe` command line tool on behalf of the app.
///
/// The app deliberately does not reimplement any of the pipeline. Whisper,
/// diarization and the LLM calls all live in the Python, and this shells out to
/// exactly the command a user would type, so there is one implementation and
/// one set of settings behind both.
///
/// Runs are queued, one at a time. The app now starts work on its own (new
/// recordings, missing notes, Voice Memos), and a second run started over the
/// first used to kill it: a click on Generate Notes during an hour-long
/// transcription threw the transcription away. A click now goes to the front of
/// the queue instead.
@MainActor
@Observable
final class Pipeline {
    enum State: Equatable {
        case idle
        case running(String)
        case finished(String)
        case failed(String)
    }

    /// One run of the command line tool.
    struct Job: Identifiable, Equatable {
        enum Kind: Equatable {
            case process(URL)
            case reprocess(URL)
            case notes(URL)
            case categorise([URL])
            case voiceMemos
            case tidy
        }

        let id = UUID()
        let kind: Kind
        let arguments: [String]
        let label: String
        /// The meeting folder this run writes into, so the view showing it
        /// knows to reload.
        let target: URL?
        /// Started by the app rather than by a click.
        let automatic: Bool

        static func == (lhs: Job, rhs: Job) -> Bool { lhs.id == rhs.id }

        /// The recording this run processes, if it processes one.
        var source: URL? {
            switch kind {
            case .process(let url), .reprocess(let url): url
            default: nil
            }
        }
    }

    enum Outcome: Equatable {
        case succeeded
        case failed
        case cancelled
        /// Another `transcribe` process already had the file (exit 75).
        case busyElsewhere
        /// The CLI needs a permission the app has to ask for (exit 77).
        case needsPermission
    }

    /// A finished run. Published as a value with a token, not through `state`:
    /// when one run ends and the next starts in the same turn, `state` goes
    /// from running to running and the finish in between is never observed.
    struct Completion: Equatable {
        let token: Int
        let job: Job
        let outcome: Outcome
        let output: String
        /// Folders the run renamed, old path to new.
        let renamed: [URL: URL]

        static func == (lhs: Completion, rhs: Completion) -> Bool { lhs.token == rhs.token }
    }

    private(set) var state: State = .idle
    private(set) var output: String = ""
    private(set) var current: Job?
    private(set) var queued: [Job] = []
    private(set) var lastCompletion: Completion?
    private var completions = 0

    /// Told about every finished run, for the work that has to follow one
    /// whether or not a window is open.
    var onCompletion: ((Completion) -> Void)?

    /// Recording failures, kept apart from `state` so they cannot overwrite a
    /// transcription that is still running.
    private(set) var recordError: String?
    private(set) var recordOutput: String = ""

    func clearRecordError() { recordError = nil; recordOutput = "" }
    func setRecordError(_ message: String?) { recordError = message }

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

    var isRunning: Bool { current != nil }

    /// True when a run concerning this kind of work is running or waiting.
    func has(_ kind: Job.Kind) -> Bool {
        current?.kind == kind || queued.contains { $0.kind == kind }
    }

    /// The run for this recording, running or waiting, if there is one.
    func job(for source: URL) -> Job? {
        if current?.source == source { return current }
        return queued.first { $0.source == source }
    }

    func isQueued(_ job: Job) -> Bool { queued.contains(job) }

    /// Stop the running command. The next queued run then starts.
    ///
    /// Cancelling the Swift task is not enough: the `Process` runs whisper and
    /// LLM calls for minutes and knows nothing about task cancellation. The
    /// child is signalled, and the run reports itself cancelled when it exits.
    func cancel() {
        guard current != nil else { return }
        wasCancelled = true
        box.terminate()
    }

    /// Drop everything waiting. What is running carries on.
    func clearQueue() { queued.removeAll() }

    // MARK: - Work

    /// Reprocess one meeting folder's recording, which regenerates its notes.
    func regenerate(folder: MeetingFolder, media: URL?, label: String) {
        guard let media else {
            state = .failed("This meeting has no recording to reprocess.")
            return
        }
        // --keep-source, or the run moves this meeting's own recording out of
        // the folder being reprocessed and into whichever new folder it
        // produces, leaving a duplicate meeting and a folder with no media.
        enqueue(
            Job(
                kind: .reprocess(media),
                arguments: [media.path(percentEncoded: false), "--keep-source"],
                label: label, target: folder.id, automatic: false),
            first: true)
    }

    /// Write notes from the transcript a folder already has.
    ///
    /// The cheap path, and the right default. Re-transcribing an hour of audio
    /// to produce notes from words the folder already contains is wasteful, and
    /// for older meetings the audio may not even be there any more.
    func notesFromTranscript(folder: URL, automatic: Bool = false) {
        enqueue(
            Job(
                kind: .notes(folder),
                arguments: ["notes", folder.path(percentEncoded: false)],
                label: automatic
                    ? "Writing notes for \(folder.lastPathComponent)"
                    : "Writing notes from the transcript",
                target: folder, automatic: automatic),
            first: !automatic)
    }

    /// Process one recording from the watch folder.
    func process(_ url: URL, automatic: Bool = false) {
        // A watch-folder recording is meant to be filed, so the source moves.
        enqueue(
            Job(
                kind: .process(url),
                arguments: [url.path(percentEncoded: false)],
                label: "Processing \(url.lastPathComponent)",
                target: nil, automatic: automatic),
            first: !automatic)
    }

    /// Ask the CLI to categorise meetings using the configured LLM.
    ///
    /// The provider, key, model and prompt all live in the Python already;
    /// re-implementing an LLM client here would be a second thing to configure
    /// and a second thing to get wrong.
    func categorise(folders: [URL], overwrite: Bool = false) {
        guard !folders.isEmpty else { return }
        var arguments = ["categorise"] + folders.map { $0.path(percentEncoded: false) }
        if overwrite { arguments.append("--overwrite") }
        enqueue(
            Job(
                kind: .categorise(folders),
                arguments: arguments,
                label: folders.count == 1
                    ? "Categorising 1 meeting" : "Categorising \(folders.count) meetings",
                target: folders.count == 1 ? folders[0] : nil, automatic: false),
            first: true)
    }

    /// Import Voice Memos recorded in the last few days that have not been
    /// imported yet. The CLI keeps the record of which have.
    func importVoiceMemos(lookbackDays: Int, automatic: Bool = false) {
        enqueue(
            Job(
                kind: .voiceMemos,
                arguments: ["voicememos", "--import", "--since-days=\(max(lookbackDays, 1))"],
                label: "Importing new Voice Memos",
                target: nil, automatic: automatic),
            first: !automatic)
    }

    /// File recordings that were processed but left in the watch folder.
    func tidy() {
        enqueue(
            Job(
                kind: .tidy, arguments: ["tidy"],
                label: "Moving processed recordings out of the watch folder",
                target: nil, automatic: false),
            first: true)
    }

    /// Queue a run, unless the same work is already running or waiting.
    func enqueue(_ job: Job, first: Bool = false) {
        guard !has(job.kind) else { return }
        if first { queued.insert(job, at: 0) } else { queued.append(job) }
        startNext()
    }

    private func startNext() {
        guard current == nil, !queued.isEmpty else { return }
        let job = queued.removeFirst()
        current = job
        wasCancelled = false
        state = .running(job.label)
        output = ""

        guard let tool = Self.locate() else {
            // Every queued run would fail the same way, so they go too.
            queued.removeAll()
            complete(job, status: 127, signalled: false, output: missingToolMessage)
            state = .failed(missingToolMessage)
            return
        }

        let box = ProcessBox()
        self.box = box
        task = Task { [weak self] in
            let result = await Self.execute(tool: tool, arguments: job.arguments, box: box)
            box.release()
            self?.complete(
                job, status: result.status, signalled: result.signalled, output: result.output)
        }
    }

    private func complete(_ job: Job, status: Int32, signalled: Bool, output: String) {
        guard current?.id == job.id else { return }
        self.output = output

        let outcome: Outcome
        if signalled {
            outcome = wasCancelled ? .cancelled : .failed
            // Anything signalled while we were not cancelling was killed from
            // outside, which is worth saying rather than calling it a generic
            // failure.
            state = wasCancelled ? .idle : .failed("\(job.label) was stopped (signal \(status)).")
        } else {
            switch status {
            case 0:
                outcome = .succeeded
                state = .finished(job.label)
            case 75:
                outcome = .busyElsewhere
                state = .finished("Another transcribe process is already on it")
            case 77:
                outcome = .needsPermission
                state = .failed("\(job.label) needs a permission macOS has not granted.")
            default:
                outcome = .failed
                state = .failed("\(job.label) failed (exit \(status)). See the log below.")
            }
        }

        completions += 1
        let completion = Completion(
            token: completions, job: job, outcome: outcome, output: output,
            renamed: Self.renames(in: output, target: job.target))
        lastCompletion = completion
        current = nil
        task = nil
        wasCancelled = false
        onCompletion?(completion)
        startNext()
    }

    /// The folder a notes run renamed, from the line the CLI prints for it.
    nonisolated static func renames(in output: String, target: URL?) -> [URL: URL] {
        guard let target else { return [:] }
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: renamedMarker) else { continue }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return [target: URL(filePath: path)] }
        }
        return [:]
    }

    /// `from_transcript.RENAMED_PREFIX` in the CLI. The two must match.
    nonisolated static let renamedMarker = "Renamed folder to: "

    /// Start or stop an OBS recording via the CLI, which already speaks
    /// obs-websocket.
    ///
    /// Awaited and returning success, so the caller does not claim a recording
    /// started when OBS refused. This deliberately does not go through the
    /// queue: it must not wait behind a long transcription.
    @discardableResult
    func controlRecording(start: Bool) async -> Bool {
        guard let tool = Self.locate() else {
            recordError = missingToolMessage
            return false
        }
        let result = await Self.execute(
            tool: tool,
            arguments: ["record", start ? "start" : "stop"],
            box: ProcessBox()
        )
        if result.status != 0 || result.signalled {
            recordError =
                (start ? "Could not start recording" : "Could not stop recording")
                + " (exit \(result.status))."
            recordOutput = result.output
        } else {
            recordError = nil
            recordOutput = ""
        }
        return result.status == 0 && !result.signalled
    }

    private var missingToolMessage: String {
        "The transcribe command line tool was not found. Install it with "
            + "'brew install calebsargeant/tap/transcribe'."
    }

    /// Runs the tool and collects its output.
    ///
    /// Reading both pipes concurrently matters: the pipeline is chatty, and a
    /// child that fills the pipe buffer while the parent waits on `exit` is a
    /// deadlock rather than a slow run.
    private nonisolated static func execute(
        tool: URL, arguments: [String], box: ProcessBox
    ) async -> (status: Int32, signalled: Bool, output: String) {
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
                    continuation.resume(
                        returning: (-1, false, "Could not start: \(error.localizedDescription)"))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: (
                        process.terminationStatus,
                        // A signal is reported as its number, which reads like
                        // an exit status unless the reason is checked.
                        process.terminationReason == .uncaughtSignal,
                        String(data: data, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }
}
