import SwiftUI

/// The generated notes: summary, themes, decisions, next steps, and the
/// timestamped walkthrough.
///
/// The pipeline also writes `notes.html`, but rendering that in a web view
/// would mean shipping a second styling system and losing the timestamp links,
/// so the JSON is laid out natively instead.
struct NotesPane: View {
    let record: MeetingRecord?
    let legacySummary: String?
    let loadError: String?
    var missing: Missing = .canWrite
    var onWrite: () -> Void = {}
    let onSeek: (Double) -> Void

    /// What stands between this meeting and its notes, so the empty state can
    /// offer the one thing that fixes it rather than just reporting the gap.
    enum Missing: Equatable {
        /// A transcript and a provider: one click away.
        case canWrite
        /// A run for this meeting is going, or waiting its turn.
        case writing
        /// Nothing to write them with.
        case noProvider
        /// Nothing to write them from.
        case noTranscript
    }

    var body: some View {
        if record?.notes == nil, legacySummary?.isEmpty ?? true, loadError == nil {
            // Outside the scroll view and filling the pane, so it sits in the
            // middle. Inside, it hugged the top left corner, which on a large
            // display put it a long way from anywhere the eye goes.
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }

                    if let notes = record?.notes {
                        notesBody(notes)
                    } else if let legacySummary, !legacySummary.isEmpty {
                        Section8("Summary") {
                            Text(legacySummary)
                                .textSelection(.enabled)
                        }
                        Text("This meeting predates structured notes. Only the summary and transcript were saved.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if missing == .canWrite {
                            Button("Write Full Notes", action: onWrite)
                                .help("Write decisions, action items and a walkthrough from the transcript")
                        }
                    }
                }
                .padding(24)
                // A reading column, centred, so a wide window does not leave it
                // stranded against the left edge.
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(missing == .writing ? "Writing notes" : "No notes yet", systemImage: "doc.text")
        } description: {
            Text(emptyDescription)
        } actions: {
            switch missing {
            case .canWrite:
                Button("Write Notes", action: onWrite)
                    .buttonStyle(.borderedProminent)
                    .help("Write notes from the transcript this meeting already has")
            case .writing:
                ProgressView().controlSize(.small)
            case .noProvider:
                SettingsLink {
                    Text("Open Settings…")
                }
            case .noTranscript:
                EmptyView()
            }
        }
    }

    private var emptyDescription: String {
        switch missing {
        case .canWrite:
            "There is a transcript, but no notes have been written from it."
        case .writing:
            "Notes are being written from the transcript. They appear here when they are done."
        case .noProvider:
            "Notes need an API key for Claude, or for an OpenAI-compatible provider. Add one in Settings, under Notes."
        case .noTranscript:
            "There is no transcript to write notes from yet."
        }
    }

    @ViewBuilder
    private func notesBody(_ notes: MeetingRecord.Notes) -> some View {
        if let summary = notes.summary, !summary.isEmpty {
            Text(summary)
                .font(.title3)
                .textSelection(.enabled)
        }

        if let event = record?.calendarEvent {
            Section8("From your calendar") {
                if let title = event.title { Text(title).fontWeight(.medium) }
                if !event.attendees.isEmpty {
                    Text(event.attendees.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                if let location = event.location, !location.isEmpty {
                    Text(location).foregroundStyle(.secondary)
                }
            }
        }

        if !notes.nextSteps.isEmpty {
            Section8("Next steps") {
                ForEach(notes.nextSteps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        // Decorative: the tickable list lives in Action
                        // items, so this must not read as a control.
                        Image(systemName: "square")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(step.title).fontWeight(.medium)
                                if let owner = step.assignedOwner {
                                    Text(owner)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                }
                            }
                            if !step.detail.isEmpty {
                                Text(step.detail).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }

        if !notes.decisions.isEmpty {
            Section8("Decisions") {
                ForEach(notes.decisions) { decision in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(
                                systemName: decision.status == .aligned
                                    ? "checkmark.circle.fill" : "questionmark.circle"
                            )
                            .foregroundStyle(decision.status == .aligned ? .green : .orange)
                            Text(decision.title).fontWeight(.medium)
                        }
                        Text(decision.detail).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
        }

        ForEach(notes.sections) { section in
            Section8(section.heading) {
                Text(section.body).textSelection(.enabled)
            }
        }

        if !notes.details.isEmpty {
            Section8("Walkthrough") {
                ForEach(notes.details) { detail in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail.heading).fontWeight(.medium)
                        Text(detail.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !detail.timestamps.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(detail.timestamps, id: \.self) { stamp in
                                    // A Button, not a tappable Text: it needs
                                    // to be a real control for keyboard and
                                    // VoiceOver to reach it.
                                    Button(stamp) {
                                        if let seconds = Timecode.seconds(from: stamp) {
                                            onSeek(seconds)
                                        }
                                    }
                                    .buttonStyle(.link)
                                    .font(.callout.monospacedDigit())
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }

        if !notes.corrections.isEmpty {
            Section8("Terms the transcript got wrong") {
                ForEach(notes.corrections) { correction in
                    HStack(spacing: 6) {
                        Text(correction.heard).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(correction.correct)
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
    }
}

/// A titled block. Named for its spacing so it does not shadow `SwiftUI.Section`.
struct Section8<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `HH:MM:SS` as the pipeline writes it everywhere.
enum Timecode {
    static func seconds(from text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// `Int(Double)` traps on NaN, on infinity, and on anything outside Int's
    /// range. A hand-edited or truncated notes.json reaches this, and a trap
    /// takes the whole app down rather than showing one wrong duration.
    static func text(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1e9 else { return "--:--:--" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Whole minutes, or nil when the value is not a usable duration.
    static func minutes(from seconds: Double) -> Int? {
        guard seconds.isFinite, seconds > 0, seconds < 1e9 else { return nil }
        return Int(seconds / 60)
    }
}
