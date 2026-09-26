import AppKit
import CryptoKit
import Foundation

/// Starts and stops OBS recordings over obs-websocket 5, from the app itself.
///
/// Recording used to go through `transcribe record start`, which needs the
/// `obsws-python` extra. The Homebrew build of the CLI does not bundle it, so
/// every automatic start failed with an import error that only ever appeared
/// as "exit 1" in the menu bar. The protocol is small enough that speaking it
/// here removes the dependency rather than documenting it.
enum OBS {
    struct Connection: Sendable, Equatable {
        var host: String
        var port: Int
        var password: String
    }

    enum Failure: LocalizedError, Equatable {
        case notInstalled
        case unreachable(String)
        case authentication
        case refused(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "OBS is not installed. Get it from obsproject.com, then enable its WebSocket server."
            case .unreachable(let detail):
                "OBS is not answering (\(detail)). Enable OBS ▸ Tools ▸ WebSocket Server Settings."
            case .authentication:
                "OBS rejected the WebSocket password. Copy it from OBS ▸ Tools ▸ WebSocket Server Settings into Settings ▸ Recording."
            case .refused(let detail):
                "OBS refused: \(detail)"
            case .timedOut:
                "OBS did not answer in time."
            }
        }
    }

    /// What came back from one request.
    struct Response: Sendable, Equatable {
        let ok: Bool
        let code: Int
        let comment: String?
        let outputActive: Bool?
        let outputPath: String?
    }

    static let bundleID = "com.obsproject.obs-studio"

    // Request status codes from the obs-websocket protocol.
    static let outputRunning = 500
    static let outputNotRunning = 501

    /// The authentication string obs-websocket expects:
    /// base64(sha256(base64(sha256(password + salt)) + challenge)).
    static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    // MARK: - Recording

    /// Start recording into `directory`, launching OBS first if it is not open.
    ///
    /// The directory is set on every start so the file lands in the watch
    /// folder. A recording that OBS saved to its own default folder was never
    /// seen by the pipeline at all.
    @MainActor
    static func startRecording(connection: Connection, directory: URL?) async throws {
        try await ensureRunning(connection: connection)
        if let directory {
            // Older obs-websocket has no SetRecordDirectory. That only means
            // OBS keeps its own folder, which is not a reason to not record.
            _ = try? await send(
                "SetRecordDirectory",
                data: ["recordDirectory": directory.path(percentEncoded: false)],
                to: connection)
        }
        let response = try await send("StartRecord", to: connection)
        guard response.ok || response.code == outputRunning else {
            throw Failure.refused(response.comment ?? "code \(response.code)")
        }
    }

    /// Stop recording. Returns where OBS saved the file, when it says.
    static func stopRecording(connection: Connection) async throws -> String? {
        let response = try await send("StopRecord", to: connection)
        guard response.ok || response.code == outputNotRunning else {
            throw Failure.refused(response.comment ?? "code \(response.code)")
        }
        return response.outputPath
    }

    static func isRecording(connection: Connection) async throws -> Bool {
        try await send("GetRecordStatus", to: connection).outputActive ?? false
    }

    /// Check the connection and the password without changing anything.
    static func test(connection: Connection) async throws -> Bool {
        try await send("GetVersion", to: connection).ok
    }

    @MainActor
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Launch OBS if it is not running, and wait for its server to answer.
    @MainActor
    static func ensureRunning(connection: Connection) async throws {
        if isRunning { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw Failure.notInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--minimize-to-tray"]
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        // OBS takes a few seconds after launch before its server accepts a
        // connection.
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            if (try? await test(connection: connection)) == true { return }
        }
        throw Failure.unreachable("started, but its WebSocket server did not answer")
    }

    // MARK: - The protocol

    /// Open a connection, identify, send one request, and return its answer.
    ///
    /// One connection per request. Recording starts and stops a few times a
    /// day; a long-lived socket would need reconnecting after every OBS
    /// restart for no gain.
    static func send(
        _ type: String, data: [String: String] = [:], to connection: Connection,
        timeout: Double = 8
    ) async throws -> Response {
        guard let url = URL(string: "ws://\(connection.host):\(connection.port)") else {
            throw Failure.unreachable("\(connection.host):\(connection.port) is not an address")
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask {
                try await exchange(socket, type: type, data: data, password: connection.password)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                // Cancelling the socket is what unblocks a receive that would
                // otherwise wait for ever.
                socket.cancel(with: .goingAway, reason: nil)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timedOut }
            return first
        }
    }

    private static func exchange(
        _ socket: URLSessionWebSocketTask, type: String, data: [String: String], password: String
    ) async throws -> Response {
        let hello: [String: Any]
        do {
            hello = try await receive(socket)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        guard hello["op"] as? Int == 0 else { throw Failure.refused("unexpected greeting") }

        var identify: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 0]
        if let greeting = hello["d"] as? [String: Any],
            let auth = greeting["authentication"] as? [String: Any],
            let challenge = auth["challenge"] as? String,
            let salt = auth["salt"] as? String
        {
            identify["authentication"] = authentication(
                password: password, salt: salt, challenge: challenge)
        }
        try await send(socket, ["op": 1, "d": identify])

        let identified: [String: Any]
        do {
            identified = try await receive(socket)
        } catch {
            // 4009 is obs-websocket's AuthenticationFailed close code.
            if socket.closeCode.rawValue == 4009 { throw Failure.authentication }
            throw Failure.unreachable(error.localizedDescription)
        }
        guard identified["op"] as? Int == 2 else { throw Failure.authentication }

        let id = UUID().uuidString
        var request: [String: Any] = ["requestType": type, "requestId": id]
        if !data.isEmpty { request["requestData"] = data }
        try await send(socket, ["op": 6, "d": request])

        while true {
            let message = try await receive(socket)
            guard message["op"] as? Int == 7, let body = message["d"] as? [String: Any],
                body["requestId"] as? String == id
            else { continue }
            let status = body["requestStatus"] as? [String: Any]
            let payload = body["responseData"] as? [String: Any]
            return Response(
                ok: status?["result"] as? Bool ?? false,
                code: status?["code"] as? Int ?? 0,
                comment: status?["comment"] as? String,
                outputActive: payload?["outputActive"] as? Bool,
                outputPath: payload?["outputPath"] as? String)
        }
    }

    private static func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: throw Failure.refused("an unexpected message")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.refused("a message that was not an object")
        }
        return object
    }

    private static func send(_ socket: URLSessionWebSocketTask, _ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
