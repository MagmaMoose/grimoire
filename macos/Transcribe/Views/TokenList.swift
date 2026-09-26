import SwiftUI

/// An editable list of short strings, shown as removable chips.
///
/// Used for settings the pipeline stores as a YAML sequence, where a
/// comma-separated text field would quietly mangle any value containing a
/// comma.
struct TokenList: View {
    @Environment(Settings.self) private var settings
    let key: String
    let prompt: String
    let help: String

    @State private var draft = ""

    private var items: [String] { settings.list(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(item)
                            Button {
                                settings.setList(key, items.filter { $0 != item })
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(item)")
                            .help("Remove \(item)")
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }

            HStack {
                TextField(prompt, text: $draft)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text(help).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        settings.setList(key, items + [value])
        draft = ""
    }
}

/// Wraps its children onto as many lines as they need.
///
/// `LazyVGrid` cannot do this: chips are all different widths, and a fixed
/// column count leaves ragged gaps.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for row in layout(subviews: subviews, width: bounds.width) {
            subviews[row.index].place(
                at: CGPoint(x: bounds.minX + row.x, y: bounds.minY + row.y),
                proposal: ProposedViewSize(row.size)
            )
        }
    }

    private struct Placed {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGSize
        var height: CGFloat { size.height }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Placed] {
        var placed: [Placed] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            placed.append(Placed(index: index, x: x, y: y, size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return placed
    }
}
