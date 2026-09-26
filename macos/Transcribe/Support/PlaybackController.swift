import AVFoundation
import Foundation

/// Owns the `AVPlayer` for one meeting so the transcript can drive it.
///
/// Clicking a transcript line seeks the recording, which is the one interaction
/// that makes a transcript worth reading next to the video rather than instead
/// of it. That needs a single player both views hold, not a `VideoPlayer` that
/// makes its own.
@MainActor
@Observable
final class PlaybackController {
    /// What the folder actually holds. A `.wav` extracted alongside a meeting
    /// and a `.mov` of the call are both "media", and presenting the first as
    /// video gives the user a black rectangle to stare at.
    enum Kind: Equatable {
        case video
        case audio
    }

    enum Phase: Equatable {
        case none
        case checking
        case ready(Kind)
        case unplayable(String)

        var kind: Kind? {
            if case .ready(let kind) = self { return kind }
            return nil
        }

        var isReady: Bool { kind != nil }
    }

    private(set) var phase: Phase = .none
    private(set) var player: AVPlayer?
    private(set) var url: URL?
    private(set) var duration: Double = 0

    /// Discards the result of a check that a newer one has superseded.
    private var loadID = 0

    func open(_ url: URL?) async {
        loadID += 1
        let id = loadID
        teardown()

        guard let url else {
            phase = .none
            return
        }

        self.url = url
        phase = .checking

        let asset = AVURLAsset(url: url)
        do {
            // Both loaded in one call: two awaits would let a newer open()
            // interleave between them.
            let (playable, videoTracks) = try await asset.load(.isPlayable, .tracks)
            guard id == loadID else { return }
            guard playable else {
                // OBS writes .qta containers carrying Apple Positional Audio
                // and timed-metadata tracks. Whether AVFoundation opens one is
                // not something this can assume, so it reports rather than
                // silently showing an empty frame.
                phase = .unplayable("\(url.pathExtension.uppercased()) is not playable here.")
                return
            }

            let hasVideo = videoTracks.contains { $0.mediaType == .video }
            let seconds = try? await asset.load(.duration).seconds
            guard id == loadID else { return }

            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            duration = (seconds?.isFinite == true) ? (seconds ?? 0) : 0
            phase = .ready(hasVideo ? .video : .audio)
        } catch is CancellationError {
            return
        } catch {
            guard id == loadID else { return }
            phase = .unplayable(error.localizedDescription)
        }
    }

    /// Seek to a point measured from the start of the *recording*.
    ///
    /// Segment times are relative to the recording, and a split meeting's clip
    /// starts partway through it, so the clip's own offset is subtracted.
    func seek(toRecordingSecond second: Double, meetingStart: Double) {
        guard let player else { return }
        let target = max(second - meetingStart, 0)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
    }

    func teardown() {
        player?.pause()
        player = nil
        url = nil
        duration = 0
    }
}
