import Foundation

/// What counts as a recording.
///
/// One list. Two had drifted apart: the library accepted six extensions and the
/// watch queue nine, so a `.mkv` in the watch folder became a meeting whose
/// media the library then could not find.
enum Media {
    static let extensions: Set<String> = [
        "mov", "mp4", "m4v", "m4a", "qta", "wav", "mp3", "avi", "mkv",
    ]

    static func isMedia(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Extensions that only ever carry audio.
    ///
    /// Demoting `.wav` alone was not enough: a folder holding an `.m4a` beside
    /// a `.mov` could present the audio as the recording, depending on the
    /// order the directory happened to list them in.
    static let audioOnly: Set<String> = ["wav", "mp3", "m4a"]

    /// Video before audio: extracted audio usually sits beside the video it
    /// came from, and the video is what the user means by "the recording".
    /// Ties keep the filesystem's order, which is stable enough per folder.
    static func preferred(from urls: [URL]) -> URL? {
        urls.filter(isMedia).min { lhs, rhs in
            rank(lhs) < rank(rhs)
        }
    }

    private static func rank(_ url: URL) -> Int {
        audioOnly.contains(url.pathExtension.lowercased()) ? 1 : 0
    }
}
