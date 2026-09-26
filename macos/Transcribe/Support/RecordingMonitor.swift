import SwiftUI

/// Watches for a meeting and drives recording.
///
/// Detection is native, so the microphone and camera checks are attributed to
/// this app rather than to whichever terminal launched the CLI. OBS is driven
/// natively too (see `OBS`): the Homebrew CLI cannot, because it does not
/// bundle the websocket client, and that is where every automatic start went.
@MainActor
@Observable
final class RecordingMonitor {
    enum Status: Equatable {
        case idle
        case detected
        case recording
        case paused
        /// A meeting is happening and the user said not to record it.
        case skipped

        var symbol: String {
            switch self {
            case .idle: "circle.dotted"
            case .detected: "circle"
            case .recording: "record.circle.fill"
            case .paused: "pause.circle"
            case .skipped: "circle.slash"
            }
        }

        var label: String {
            switch self {
            case .idle: "Idle"
            case .detected: "Meeting detected"
            case .recording: "Recording"
            case .paused: "Auto-record paused"
            case .skipped: "Not recording this meeting"
            }
        }
    }

    private(set) var presence = Presence.State()
    private(set) var status: Status = .idle
    private(set) var detectedSince: Date?
    private(set) var quietSince: Date?
    private(set) var lastError: String?
    /// Where OBS saved the last recording, when it said.
    private(set) var lastRecordingPath: String?

    /// Set by `control` when it can say more than "it failed".
    var controlError: String?

    /// "Not this one": leave the meeting under way unrecorded, and go back to
    /// normal once the signals go quiet.
    private var skipping = false

    /// The calendar is read once a minute, not on every poll: each read opens
    /// the event store, and meetings do not start every five seconds.
    private var calendarCheckedAt: Date?
    private var calendarState: (meeting: Bool, title: String?) = (false, nil)

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
        let wantsCalendar = settings.config.bool(ConfigKey.useCalendar, default: true)
        let readCalendar =
            wantsCalendar && (calendarCheckedAt.map { now.timeIntervalSince($0) >= 60 } ?? true)
        let ignoredDevices = settings.list(ConfigKey.ignoredDevices)
        let ignoredCameras = settings.list(ConfigKey.ignoredCameras)
        var state = await MeetingLibrary.offMainActor {
            Presence.current(
                includeCalendar: readCalendar,
                ignoredDevices: ignoredDevices,
                ignoredCameras: ignoredCameras
            )
        }
        if readCalendar {
            calendarCheckedAt = now
            calendarState = (state.calendarMeeting, state.calendarTitle)
        } else if wantsCalendar {
            state.calendarMeeting = calendarState.meeting
            state.calendarTitle = calendarState.title
        }
        presence = state
        await decide(now: now)
    }

    /// Leave the meeting under way unrecorded.
    func skipCurrentMeeting() {
        guard status == .detected else { return }
        skipping = true
        detectedSince = nil
        status = .skipped
    }

    /// Whether meetings start a recording on their own. Off, the signals are
    /// still read, so the menu can say what it sees, and Record Now still works.
    private var automatic: Bool { settings.config.bool(ConfigKey.autoRecord, default: true) }

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
            if automatic, let quietSince, now.timeIntervalSince(quietSince) >= stopDelay {
                await setRecording(false, now: now)
            }
            return
        }

        if skipping {
            guard !active else {
                detectedSince = nil
                status = .skipped
                return
            }
            skipping = false
        }

        guard automatic else {
            detectedSince = nil
            status = .idle
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
        controlError = nil
        let succeeded = await control(recording)
        guard succeeded else {
            // A failed *stop* must stay .recording, or nothing ever retries it
            // and the recorder runs forever. Only a failed start falls back.
            lastError =
                controlError
                ?? (recording ? "Could not start the recording." : "Could not stop the recording.")
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

    /// Start or stop OBS. This is `control` in the app; tests inject their own.
    func driveOBS(start: Bool) async -> Bool {
        let connection = OBS.Connection(
            host: settings.config.string(ConfigKey.obsHost, default: "localhost"),
            port: settings.config.int(ConfigKey.obsPort, default: 4455),
            password: settings.config.string(ConfigKey.obsPassword)
        )
        do {
            if start {
                try await OBS.startRecording(
                    connection: connection, directory: settings.folder(ConfigKey.watch))
            } else {
                lastRecordingPath = try await OBS.stopRecording(connection: connection)
            }
            return true
        } catch {
            controlError =
                (start ? "Could not start recording. " : "Could not stop recording. ")
                + error.localizedDescription
            return false
        }
    }

    func clearError() { lastError = nil }

    /// Set the signals directly, so the state machine can be driven in a test
    /// without a microphone, a camera or a calendar.
    func setPresenceForTesting(_ state: Presence.State) { presence = state }

    /// Seconds until recording starts, for the menu bar.
    func waitingSeconds(now: Date = Date()) -> Int? {
        guard status == .detected, let detectedSince else { return nil }
        return max(Int(startDelay - now.timeIntervalSince(detectedSince)), 0)
    }
}
