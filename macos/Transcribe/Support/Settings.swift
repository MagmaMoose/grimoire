import SwiftUI

/// The settings the app exposes, backed by `~/.transcribe/config.yaml`.
///
/// One store, one file. The app and the CLI read the same settings from the
/// same place, so there is nothing to keep in sync and no second source of
/// truth to disagree with the first.
///
/// Every edit writes through immediately. A settings window with a Save button
/// can be left half-applied; this cannot.
@MainActor
@Observable
final class Settings {
    private(set) var config: Configuration
    private(set) var lastError: String?

    init(config: Configuration = .load()) {
        self.config = config
    }

    func reload() {
        // Anything queued was superseded by what is on disk; letting it flush
        // afterwards would write the value the user just discarded.
        writeTask?.cancel()
        pending = [:]
        config = .load()
        lastError = nil
    }

    /// Edits pending a write. A text field fires `set` on every keystroke, and
    /// each write was a synchronous read-modify-write of the whole file on the
    /// main actor -- typing an API key rewrote it fifty times.
    private var pending: [String: String] = [:]
    private var pendingLists: [String: [String]] = [:]
    private var writeTask: Task<Void, Never>?

    /// How long to wait for typing to stop. Long enough to coalesce a burst,
    /// short enough that the CLI sees an edit made moments ago.
    private static let writeDelay = Duration.milliseconds(400)

    private func set(_ key: String, _ value: String) {
        guard config.values[key] != value else { return }
        config.values[key] = value
        pending[key] = value
        scheduleWrite()
    }

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: Settings.writeDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// True while an edit has not reached disk. Sudden termination is disabled
    /// for exactly this window.
    var hasUnsavedEdits: Bool { !pending.isEmpty || !pendingLists.isEmpty }

    /// Write the pending edits now. Called on quit and when the Settings window
    /// closes, because a 400ms debounce plus Cmd-Q loses the last edit
    /// otherwise -- and `NSSupportsSuddenTermination` makes that likelier.
    func flush() async {
        guard !pending.isEmpty || !pendingLists.isEmpty else { return }
        let changes = pending
        let lists = pendingLists
        pending = [:]
        pendingLists = [:]
        // The failure has to come back across the actor hop, so it is returned
        // rather than thrown: a swallowed write leaves the user believing a
        // setting was saved when it was not.
        // Both kinds go through one hop, in order, so a scalar write and a
        // list write cannot read-modify-write the same file concurrently.
        let failure = await MeetingLibrary.offMainActor { () -> String? in
            do {
                try Configuration.write(changes)
                for (key, items) in lists.sorted(by: { $0.key < $1.key }) {
                    try Configuration.writeList(key, items)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if let failure {
            // Put the edits back, or `set`'s equality guard blocks a retry
            // forever: config.values already holds the new value, so the user
            // typing it again is a no-op.
            for (key, value) in changes where pending[key] == nil {
                pending[key] = value
            }
            for (key, items) in lists where pendingLists[key] == nil {
                pendingLists[key] = items
            }
            lastError =
                "Could not save \(Configuration.path.path(percentEncoded: false)): \(failure)"
        } else {
            lastError = nil
        }
    }

    // MARK: - Bindings
    //
    // Explicit `Binding(get:set:)` rather than key-path projection: the write
    // has to go through `set` to reach the file, and a plain factory makes that
    // obvious at every call site.

    func text(_ key: String, default fallback: String = "") -> Binding<String> {
        Binding(
            get: { self.config.string(key, default: fallback) },
            set: { self.set(key, $0) }
        )
    }

    func flag(_ key: String, default fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { self.config.bool(key, default: fallback) },
            set: { self.set(key, $0 ? "true" : "false") }
        )
    }

    func number(_ key: String, default fallback: Int) -> Binding<Int> {
        Binding(
            get: { self.config.int(key, default: fallback) },
            set: { self.set(key, String($0)) }
        )
    }

    func decimal(_ key: String, default fallback: Double) -> Binding<Double> {
        Binding(
            get: { self.config.double(key, default: fallback) },
            set: { self.set(key, String(format: "%g", $0)) }
        )
    }

    func list(_ key: String) -> [String] { config.list(key) }

    func setList(_ key: String, _ items: [String]) {
        let cleaned = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard config.lists[key] ?? [] != cleaned else { return }
        config.lists[key] = cleaned
        pendingLists[key] = cleaned
        scheduleWrite()
    }

    func folder(_ key: String) -> URL? { config.url(key) }

    func setFolder(_ key: String, _ url: URL?) {
        set(key, url?.path(percentEncoded: false) ?? "")
    }
}

/// Everything the settings window can change, with the key names the pipeline
/// actually reads. Kept in one place so a rename shows up here rather than
/// silently reading back an empty string.
enum ConfigKey {
    static let destination = "destination_directory"
    static let watch = "watch_directory"

    static let provider = "llm_provider"
    static let anthropicKey = "anthropic_api_key"
    static let anthropicModel = "anthropic_model"
    static let openAIKey = "openai_api_key"
    static let openAIModel = "openai_model"
    static let openAIBaseURL = "openai_base_url"

    static let whisperModel = "whisper_model"
    static let whisperLanguage = "whisper_language"
    static let whisperVAD = "whisper_vad"
    static let whisperAutoPrompt = "whisper_auto_prompt"
    static let whisperThreads = "whisper_threads"

    static let diarization = "diarization_enabled"
    static let diarizationThreshold = "diarization_threshold"
    static let splitMeetings = "split_meetings"
    static let splitVideo = "split_video"
    static let meetingGap = "meeting_gap_seconds"
    static let minMeeting = "min_meeting_seconds"
    static let moveSource = "move_source_video"

    static let calendar = "calendar_enabled"
    static let calendarMargin = "calendar_margin_minutes"

    static let requireCamera = "autorecord_require_camera"
    static let useCalendar = "autorecord_use_calendar"
    static let micOnly = "autorecord_mic_only"
    static let startAfter = "autorecord_start_after_seconds"
    static let stopAfter = "autorecord_stop_after_seconds"
    static let minFreeGB = "autorecord_min_free_gb"
    static let obsHost = "obs_host"
    static let obsPort = "obs_port"
    static let obsPassword = "obs_password"

    // slack.py prefers a bot token and channel, falling back to the webhook.
    // Neither bot key is in the CLI's DEFAULT_CONFIG, so the app is the only
    // place they are discoverable.
    static let slackBotToken = "slack_bot_token"
    static let slackChannel = "slack_channel_id"
    static let slackWebhook = "slack_webhook_url"

    // The app's own settings, stored alongside the CLI's so there is still one
    // file. The pipeline ignores keys it does not know.
    // Read by the pipeline but rarely touched. Exposed on the Advanced tab so
    // "every setting the CLI reads is configurable" is actually true.
    static let vadThreshold = "whisper_vad_threshold"
    static let suppressNonSpeech = "whisper_suppress_non_speech"
    static let transcriptBudget = "transcript_token_budget"
    static let boundaryBudget = "boundary_token_budget"
    static let categoryMaxTokens = "category_max_tokens"
    static let diarizationShift = "diarization_window_shift_ratio"
    static let diarizationModelDir = "diarization_model_dir"
    static let videoExtensions = "video_extensions"
    static let ignoredDevices = "autorecord_ignored_devices"
    static let ignoredCameras = "autorecord_ignored_cameras"
    static let llmTimeout = "llm_timeout_seconds"
    static let llmRetries = "llm_max_retries"

    /// Keys the app builds a dedicated control for. Anything in the file that
    /// is not here shows up in Advanced ▸ Other settings, so a key added to the
    /// pipeline cannot silently become unreachable.
    static let covered: Set<String> = [
        destination, watch, provider, anthropicKey, anthropicModel, openAIKey, openAIModel,
        openAIBaseURL, whisperModel, whisperLanguage, whisperVAD, whisperAutoPrompt,
        whisperThreads, whisperPrompt, diarization, diarizationThreshold, diarizationThreads,
        splitMeetings, splitVideo, meetingGap, minMeeting, moveSource, calendar, calendarMargin,
        calendarSource, requireCamera, useCalendar, micOnly, startAfter, stopAfter, minFreeGB,
        obsHost, obsPort, obsPassword, slackBotToken, slackChannel, slackWebhook, meetingMode,
        knownParticipants, notesFolder, remindersList, pollSeconds,
        notesMaxTokens, speakerMaxTokens, boundaryMaxTokens, vadThreshold, suppressNonSpeech,
        transcriptBudget, boundaryBudget, categoryMaxTokens, diarizationShift,
        diarizationModelDir, videoExtensions, ignoredDevices, ignoredCameras,
        llmTimeout, llmRetries, "anthropic_auth_token",
    ]

    // Deliberately NOT in `covered`. Each is read by the pipeline and has no
    // dedicated control, so listing it here would filter it out of Advanced's
    // catch-all and leave it unreachable -- the opposite of what `covered` is
    // for. They show up as editable text fields instead.
    static let notesTemperature = "notes_temperature"
    static let diarizationMinOn = "diarization_min_duration_on"
    static let diarizationMinOff = "diarization_min_duration_off"
    static let icloudBaseURL = "icloud_base_url"

    static let notesFolder = "apple_notes_folder"
    static let remindersList = "apple_reminders_list"

    static let meetingMode = "meeting_mode"
    static let calendarSource = "calendar_source"
    static let knownParticipants = "known_participants"
    static let whisperPrompt = "whisper_prompt"
    static let diarizationThreads = "diarization_threads"
    static let pollSeconds = "autorecord_poll_seconds"
    static let notesMaxTokens = "notes_max_tokens"
    static let speakerMaxTokens = "speaker_max_tokens"
    static let boundaryMaxTokens = "boundary_max_tokens"

    /// Whisper models the pipeline knows how to fetch, smallest first.
    static let whisperModels = [
        "tiny", "base", "small", "medium", "large-v3", "large-v3-turbo",
    ]
}
