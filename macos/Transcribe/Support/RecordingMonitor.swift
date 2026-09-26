import SwiftUI

/// Watches for a meeting and drives recording.
///
/// Detection is native, so the microphone and camera checks are attributed to
/// this app rather than to whichever terminal launched the CLI. Starting and
/// stopping OBS is still the CLI's job: it already speaks obs-websocket, and a
/// second implementation of that in Swift would be one more thing to keep in
/// step for no gain.
@MainActor
@Observable
final class RecordingMonitor {
    enum Status: Equatable {
        case idle
        case detected
        case recording
        case paused

        var symbol: String {
            switch self {
            case .idle: "circle.dotted"
            case .detected: "circle"
            case .recording: "record.circle.fill"
            case .paused: "pause.circle"
            }
        }

        var label: String {
            switch self {
            case .idle: "Idle"
            case .detected: "Meeting detected"
            case .recording: "Recording"
            case .paused: "Auto-record paused"
            }
        }
    }

    private(set) var presence = Presence.State()
    private(set) var status: Status = .idle
    private(set) var detectedSince: Date?
    private(set) var quietSince: Date?
    private(set) var lastError: String?

    /// Pausing means "stop deciding for me". It must not mean "abandon a
    /// recording in progress": the menu bar swaps Stop for Record Now when it
    /// is not `.recording`, so a paused recording had no stop button anywhere.
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused {
                let wasRecording = status == .recording
                detectedSince = nil
                status = .paused
                if wasRecording { Task { await stopBecausePaused() } }
            } else if status == .paused {
                status = .idle
            }
        }
    }

    private func stopBecausePaused() async {
        guard let control else { return }
        if await control(false) {
            lastError = nil
        } else {
            lastError = "Paused, but the recording could not be stopped."
        }
        quietSince = nil
    }

    /// Starts and stops the recording, returning whether it worked. Injected
    /// rather than reached for, so the monitor can be driven in a test without
    /// an OBS instance.
    var control: ((Bool) async -> Bool)?

    private var timer: Task<Void, Never>?
    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    /// A meeting needs the microphone plus one corroborating signal, unless the
    /// user has said the microphone alone is enough. The microphone on its own
    /// fires on dictation, voice notes and Siri.
    ///
    /// Turning the camera requirement *off* used to make detection impossible:
    /// the old shape returned true only when the requirement was on and the
    /// camera was in use, so relaxing it removed the only route to true.
    var meetingInProgress: Bool {
        guard presence.microphone else { return false }
        if settings.config.bool(ConfigKey.micOnly, default: false) { return true }

        // Both corroborating signals are opt-out, and each is checked against
        // its own setting. Previously the camera counted whether or not it was
        // required, so the toggle did nothing in either direction.
        if settings.config.bool(ConfigKey.requireCamera, default: true), presence.camera {
            return true
        }
        if settings.config.bool(ConfigKey.useCalendar, default: true), presence.calendarMeeting {
            return true
        }
        return false
    }

    /// How long a meeting must be detected before recording starts. Long enough
    /// that a notification chime does not produce a file.
    private var startDelay: Double {
        Double(settings.config.int(ConfigKey.startAfter, default: 45))
    }

    /// How long it must be quiet before recording stops. Long enough that
    /// swapping a headset does not chop a meeting in two.
    private var stopDelay: Double {
        Double(settings.config.int(ConfigKey.stopAfter, default: 120))
    }

    /// The interval is re-read each time round, so changing it in Advanced
    /// takes effect without relaunching.
    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let seconds = self?.settings.config.int(ConfigKey.pollSeconds, default: 5) ?? 5
                try? await Task.sleep(for: .seconds(max(seconds, 1)))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One poll: read the signals, then start or stop if the clocks say so.
    ///
    /// The previous version returned early whenever `status == .recording`,
    /// which stopped presence polling entirely and left a stuck "Recording"
    /// with no way back. Presence is always read; only the decision is
    /// conditional. It also never started anything: `readyToRecord` existed and
    /// nothing called it, so "Pause Auto-Record" paused a feature that was not
    /// running.
    func tick(now: Date = Date()) async {
        let includeCalendar = settings.config.bool(ConfigKey.useCalendar, default: true)
        let ignoredDevices = settings.list(ConfigKey.ignoredDevices)
        let ignoredCameras = settings.list(ConfigKey.ignoredCameras)
        presence = await MeetingLibrary.offMainActor {
            Presence.current(
                includeCalendar: includeCalendar,
                ignoredDevices: ignoredDevices,
                ignoredCameras: ignoredCameras
            )
        }
        await decide(now: now)
    }

    /// The state machine, separated from the polling so a test can drive it
    /// with a clock rather than by waiting.
    func decide(now: Date = Date()) async {
        let active = meetingInProgress

        if active {
            quietSince = nil
            if detectedSince == nil { detectedSince = now }
        } else {
            detectedSince = nil
            if quietSince == nil { quietSince = now }
        }

        guard !paused else {
            status = .paused
            return
        }

        if status == .recording {
            if let quietSince, now.timeIntervalSince(quietSince) >= stopDelay {
                await setRecording(false, now: now)
            }
            return
        }

        if let detectedSince, now.timeIntervalSince(detectedSince) >= startDelay {
            guard await enoughFreeSpace() else {
                lastError = "Not enough free space to start recording."
                status = .detected
                return
            }
            await setRecording(true, now: now)
            return
        }

        status = active ? .detected : .idle
    }

    /// Refuse to start below the configured floor: a truncated recording on a
    /// full disk loses the meeting entirely.
    private func enoughFreeSpace() async -> Bool {
        let floor = Int64(settings.config.int(ConfigKey.minFreeGB, default: 10))
        guard floor > 0 else { return true }
        let watch =
            settings.folder(ConfigKey.watch) ?? FileManager.default.homeDirectoryForCurrentUser
        // Statting a volume can block on a network or cloud mount, and this
        // runs on every poll.
        let free = await MeetingLibrary.offMainActor {
            (try? watch.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity ?? Int.max
        }
        return Int64(free) >= floor * 1_000_000_000
    }

    /// Start or stop, and only claim the state the recorder actually reached.
    ///
    /// Takes the clock rather than reading it, so the whole machine runs on one
    /// time source. Reading `Date()` here left the clocks it sets on a
    /// different timeline from the ones `decide(now:)` compares them against.
    func setRecording(_ recording: Bool, now: Date = Date()) async {
        guard let control else {
            lastError = "No recorder is connected."
            return
        }
        let succeeded = await control(recording)
        guard succeeded else {
            // A failed *stop* must stay .recording, or nothing ever retries it
            // and the recorder runs forever. Only a failed start falls back.
            lastError =
                recording ? "Could not start the recording." : "Could not stop the recording."
            if recording {
                status = meetingInProgress ? .detected : .idle
                // Back off rather than retrying every poll against an OBS that
                // is not there.
                detectedSince = nil
            }
            return
        }

        lastError = nil
        if recording {
            status = .recording
            // Both clocks reset on a start. Without this the stop test is
            // already satisfied by whatever quiet preceded a manual start, and
            // the next poll stops the recording the user just asked for.
            quietSince = meetingInProgress ? nil : now
            detectedSince = now
        } else {
            status = meetingInProgress ? .detected : .idle
            detectedSince = nil
            quietSince = nil
        }
    }

    /// Set the signals directly, so the state machine can be driven in a test
    /// without a microphone, a camera or a calendar.
    func setPresenceForTesting(_ state: Presence.State) { presence = state }

    /// Seconds until recording starts, for the menu bar.
    func waitingSeconds(now: Date = Date()) -> Int? {
        guard status == .detected, let detectedSince else { return nil }
        return max(Int(startDelay - now.timeIntervalSince(detectedSince)), 0)
    }
}
