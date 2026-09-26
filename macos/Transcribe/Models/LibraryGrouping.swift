import Foundation

/// How the sidebar sorts meetings into sections.
///
/// By month is the default because it needs nothing. The others are the user
/// deciding what a meeting belongs to: its category, or one of the fields they
/// defined in `group_fields`, such as Company or Project.
enum LibraryGrouping: Hashable, Sendable {
    case month
    case category
    case field(String)

    /// How the choice is stored, since `@AppStorage` holds strings.
    var id: String {
        switch self {
        case .month: "month"
        case .category: "category"
        case .field(let name): "field:\(name)"
        }
    }

    init(id: String) {
        if id == "category" {
            self = .category
        } else if id.hasPrefix("field:"), id.count > "field:".count {
            self = .field(String(id.dropFirst("field:".count)))
        } else {
            self = .month
        }
    }

    var label: String {
        switch self {
        case .month: "Month"
        case .category: "Category"
        case .field(let name): name
        }
    }

    /// The section for meetings that have no value, always listed last.
    var emptyGroup: String {
        switch self {
        case .month: "Undated"
        case .category: "Uncategorised"
        case .field(let name): "No \(name)"
        }
    }

    /// Sections in display order, each holding its meetings in the order given.
    ///
    /// `folders` arrives newest first, so a month's position is its date, and a
    /// category's is its most recent meeting: whatever was worked on last sits
    /// at the top. A meeting sits under its first category only, because the
    /// same row selected in two sections at once reads as two meetings.
    static func groups(
        _ folders: [MeetingFolder],
        by grouping: LibraryGrouping,
        categories: (URL) -> [String],
        field: (String, URL) -> String?
    ) -> [(key: String, value: [MeetingFolder])] {
        var order: [String] = []
        var buckets: [String: [MeetingFolder]] = [:]
        let empty = grouping.emptyGroup

        for folder in folders {
            let key: String
            switch grouping {
            case .month:
                key = folder.date.map { $0.formatted(.dateTime.month(.wide).year()) } ?? empty
            case .category:
                key = categories(folder.id).first ?? empty
            case .field(let name):
                key = field(name, folder.id) ?? empty
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(folder)
        }

        if let position = order.firstIndex(of: empty) {
            order.remove(at: position)
            order.append(empty)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
