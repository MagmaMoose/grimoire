import AVFoundation
import AppKit
import CoreAudio
import EventKit
import Foundation

/// Whether the microphone and camera are in use, right now.
///
/// Implemented natively rather than shelling out to the CLI for one reason
/// that matters: macOS attributes a permission to the *responsible* process,
/// which for the CLI is whichever terminal launched it. Asking here means the
/// grant belongs to Transcribe.app and survives.
///
/// Neither property needs any permission of its own — they report whether a
/// device is running, not what it is capturing — so this can poll without ever
/// prompting.
enum Presence {
    struct State: Equatable, Sendable {
        var microphone = false
        var camera = false
        var calendarMeeting = false
        var microphoneNames: [String] = []
        var cameraNames: [String] = []
        var calendarTitle: String?
        /// The apps holding the microphone, where macOS can say (14.2 and later).
        var microphoneApps: [String] = []

        var describe: String {
            var parts: [String] = []
            let holders = microphoneApps.isEmpty ? microphoneNames : microphoneApps
            parts.append(
                microphone ? "mic on (\(holders.joined(separator: ", ")))" : "mic off")
            parts.append(camera ? "camera on (\(cameraNames.joined(separator: ", ")))" : "camera off")
            if let calendarTitle { parts.append("in “\(calendarTitle)”") }
            return parts.joined(separator: " · ")
        }
    }

    /// Virtual and loopback inputs report as running whenever their host app is
    /// open, so they say nothing about whether a meeting is happening.
    static let ignoredDevices = [
        "blackhole", "loopback", "soundflower", "zoomaudiodevice", "krisp",
        "steam streaming", "obs virtual", "ishowu", "aggregate", "multi-output",
        "background music", "vb-cable", "existential audio",
    ]

    static let ignoredCameras = [
        "obs virtual", "capture screen", "mmhmm", "snap camera", "desk view",
    ]

    static func isIgnored(_ name: String, in list: [String]) -> Bool {
        let lowered = name.lowercased()
        return list.contains { lowered.contains($0) }
    }

    /// The signals right now.
    ///
    /// The ignore lists are passed in rather than read from the hardcoded
    /// defaults, because the Advanced tab lets the user add to them and those
    /// settings were write-only: configured and never consulted.
    static func current(
        includeCalendar: Bool = true,
        ignoredDevices: [String] = [],
        ignoredCameras: [String] = []
    ) -> State {
        var state = State()
        state.microphoneNames = runningMicrophones(
            ignoring: ignoredDevices.isEmpty ? self.ignoredDevices : ignoredDevices)
        state.microphone = !state.microphoneNames.isEmpty
        if state.microphone, let apps = inputApps(), !apps.isEmpty {
            let others = apps.filter { !ownMicrophoneUsers.contains($0) }
            state.microphoneApps = others.map(appName)
            // OBS holds the microphone for as long as it is open, recording or
            // not. Counted, the recording it started kept itself going for
            // ever, and any calendar event made an idle OBS look like a
            // meeting. Only a positive sighting of nothing but OBS clears the
            // signal: an empty or unreadable list leaves the device's word.
            if others.isEmpty { state.microphone = false }
        }
        state.cameraNames = runningCameras(
            ignoring: ignoredCameras.isEmpty ? self.ignoredCameras : ignoredCameras)
        state.camera = !state.cameraNames.isEmpty
        if includeCalendar, let event = currentCalendarEvent() {
            state.calendarMeeting = true
            state.calendarTitle = event
        }
        return state
    }

    /// The title of an event happening right now, if the calendar is readable.
    ///
    /// `authorizationStatus` never prompts, so a user who has not granted
    /// calendar access simply gets no calendar signal rather than a dialog
    /// every five seconds.
    static func currentCalendarEvent() -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(3600),
            calendars: nil
        )
        return store.events(matching: predicate)
            .first { event in
                guard !event.isAllDay, let start = event.startDate, let end = event.endDate
                else { return false }
                return start <= now && end >= now
            }?
            .title
    }

    // MARK: - Calendar access

    /// Whether the calendar can be read. Without it the calendar signal is
    /// silently never there, so a camera-off meeting is never recorded.
    static var calendarAuthorised: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Ask for calendar access. Granted to this app, it also covers the CLI
    /// runs this app starts, which macOS attributes to it.
    static func requestCalendarAccess() async -> Bool {
        if calendarAuthorised { return true }
        return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    // MARK: - Which apps hold the microphone

    /// Apps whose own use of the microphone says nothing about a meeting: OBS
    /// captures it for the recording, and this app never should.
    static let ownMicrophoneUsers: Set<String> = [
        "com.obsproject.obs-studio", "com.magmamoose.transcribe",
    ]

    /// Bundle identifiers of the processes using audio input right now, or nil
    /// where macOS cannot say.
    static func inputApps() -> [String]? {
        guard #available(macOS 14.2, *) else { return nil }
        return processesUsingInput()
    }

    @available(macOS 14.2, *)
    private static func processesUsingInput() -> [String]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else {
            return nil
        }
        return processes.compactMap { process in
            guard isRunningInput(process) else { return nil }
            return bundleIdentifier(of: process) ?? "process \(process)"
        }
    }

    @available(macOS 14.2, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    @available(macOS 14.2, *)
    private static func bundleIdentifier(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var identifier: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &identifier) == noErr
        else { return nil }
        let text = identifier as String
        return text.isEmpty ? nil : text
    }

    /// A readable name for a bundle identifier, for the menu's signal line.
    static func appName(_ bundleIdentifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
    }

    // MARK: - Microphone

    /// Input devices reporting `kAudioDevicePropertyDeviceIsRunningSomewhere`.
    static func runningMicrophones(ignoring list: [String]? = nil) -> [String] {
        let ignore = list ?? ignoredDevices
        return deviceIDs().compactMap { device in
            guard hasInputStreams(device), isRunningSomewhere(device) else { return nil }
            guard let name = deviceName(device), !isIgnored(name, in: ignore) else {
                return nil
            }
            return name
        }
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }
        return name as String
    }

    // MARK: - Camera

    /// `AVCaptureDevice.isInUseByAnotherApplication` needs no camera permission
    /// of its own, which is what lets this poll quietly.
    static func runningCameras(ignoring list: [String]? = nil) -> [String] {
        let ignore = list ?? ignoredCameras
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
            .filter { $0.isInUseByAnotherApplication }
            .map(\.localizedName)
            .filter { !isIgnored($0, in: ignore) }
    }
}
