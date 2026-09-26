import SwiftUI

/// `transcribe doctor` and `transcribe mic`, in a window.
///
/// Both answer "why is this not working", and both were only reachable from a
/// terminal: which tools are missing, whether a key is set, whether calendar
/// access was granted, and which inputs and cameras look busy right now.
struct DiagnosticsView: View {
    @State private var report: String = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Checks the tools, models, keys and permissions the pipeline needs.")
                    .foregroundStyle(.secondary)
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("Run Again") { Task { await run() } }
                    .disabled(running)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled(report.isEmpty)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(report.isEmpty ? "Running…" : report)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await run() }
    }

    private func run() async {
        running = true
        defer { running = false }
        guard let tool = Pipeline.locate() else {
            report =
                "The transcribe command line tool was not found.\n\n"
                + "Install it with: brew install calebsargeant/tap/transcribe"
            return
        }
        let doctor = await Self.capture(tool, ["doctor"])
        let devices = await Self.capture(tool, ["mic"])
        report = doctor + "\n" + devices
    }

    /// Run one command and return everything it printed.
    private nonisolated static func capture(_ tool: URL, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "Could not run transcribe \(arguments.joined(separator: " ")): \(error.localizedDescription)\n")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
