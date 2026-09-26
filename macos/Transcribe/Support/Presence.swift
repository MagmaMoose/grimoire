import AVFoundation
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

        var describe: String {
            var parts: [String] = []
            parts.append(
                microphone ? "mic on (\(microphoneNames.joined(separator: ", ")))" : "mic off")
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
