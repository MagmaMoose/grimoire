import AVKit
import SwiftUI

/// The recording, presented as what it actually is.
///
/// An audio-only file in an `AVPlayerView` sized for video is a large black
/// rectangle with a scrubber under it. Audio gets a compact bar instead, which
/// is both honest about the content and leaves the transcript the room it
/// deserves.
struct MediaPane: View {
    let playback: PlaybackController
    let media: URL?
    /// True when the file is not in this meeting's own folder.
    var isElsewhere = false

    var body: some View {
        switch playback.phase {
        case .none:
            Color.clear
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let kind):
            if let player = playback.player {
                VStack(spacing: 0) {
                    switch kind {
                    case .video:
                        PlayerRepresentable(player: player, showsVideo: true)
                    case .audio:
                        AudioBar(player: player, url: media, duration: playback.duration)
                    }
                    if isElsewhere, let media {
                        ElsewhereNote(media: media)
                    }
                }
            }
        case .unplayable(let reason):
            ContentUnavailableView {
                Label("Cannot play this recording", systemImage: "waveform.slash")
            } description: {
                Text(reason)
            } actions: {
                if let media {
                    Button("Open in QuickTime") { NSWorkspace.shared.open(media) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([media])
                    }
                }
            }
        }
    }

    /// How much height this pane wants. Audio needs a bar, not a screen.
    var preferredHeight: CGFloat? {
        switch playback.phase {
        case .ready(.audio): 68 + (isElsewhere ? 24 : 0)
        case .ready(.video), .checking, .unplayable: nil
        case .none: 0
        }
    }
}

/// A compact transport for audio-only recordings.
private struct AudioBar: View {
    let player: AVPlayer
    let url: URL?
    let duration: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(url?.lastPathComponent ?? "Audio recording")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    Timecode.minutes(from: duration) != nil
                        ? "Audio only · \(Timecode.text(from: duration))"
                        : "Audio only"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // AVPlayerView with no video still gives the standard transport,
            // scrubber and audio-track picker, which is worth far more than a
            // hand-rolled play button.
            PlayerRepresentable(player: player, showsVideo: false)
                .frame(width: 320, height: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ElsewhereNote: View {
    let media: URL

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Playing the original recording, which is not in this folder.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([media])
            }
            .buttonStyle(.link).font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// `AVPlayerView` rather than SwiftUI's `VideoPlayer`.
///
/// `VideoPlayer` gives no way to keep a player across view updates, and this
/// screen needs the transcript to seek the same player the user is watching.
/// `AVPlayerView` also brings the macOS transport controls, including the
/// scrubber and the audio-track picker, which matters for OBS recordings that
/// carry more than one audio track.
struct PlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var showsVideo = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = showsVideo
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.showsFullScreenToggleButton = showsVideo
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
