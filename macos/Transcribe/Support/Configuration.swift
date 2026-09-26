import Foundation

/// Reads and writes `~/.transcribe/config.yaml`, the file the CLI runs on.
///
/// Edits are surgical: the line for a key is rewritten in place and everything
/// else in the file is left byte for byte alone, so the comments explaining
/// every setting survive. That is strictly better than the CLI's own
/// `save_config`, which round-trips through `yaml.dump` and drops all of them.
///
/// Only top-level scalars are modelled. Keys holding lists or nested maps are
/// read as absent and never written, so a setting this does not understand
/// cannot be corrupted by it.
struct Configuration: Sendable, Equatable {
    var values: [String: String]
    /// Block sequences, kept apart from scalars so a list is never flattened
    /// into a string and written back as one.
    var lists: [String: [String]] = [:]

    static let path = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".transcribe/config.yaml")

    // MARK: - Reading

    static func load(from url: URL = path) -> Configuration {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Configuration(values: [:])
        }
        return Configuration(values: scalars(in: text), lists: sequences(in: text))
    }

    func string(_ key: String, default fallback: String = "") -> String {
        values[key] ?? fallback
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        guard let raw = values[key]?.lowercased() else { return fallback }
        return ["true", "yes", "on", "1"].contains(raw)
    }

    func int(_ key: String, default fallback: Int) -> Int {
        values[key].flatMap(Int.init) ?? fallback
    }

    func double(_ key: String, default fallback: Double) -> Double {
        values[key].flatMap(Double.init) ?? fallback
    }

    func url(_ key: String) -> URL? {
        guard let raw = values[key], !raw.isEmpty else { return nil }
        return URL(filePath: raw)
    }

    /// A block-sequence value, as `known_participants` is written.
    func list(_ key: String) -> [String] {
        lists[key] ?? []
    }

    /// Convenience for the two settings the app itself depends on.
    var destinationDirectory: URL? { url("destination_directory") }
    var watchDirectory: URL? { url("watch_directory") }

    // MARK: - Writing

    enum WriteError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return detail
            }
        }
    }

    /// Apply changed keys to the file on disk, leaving everything else intact.
    ///
    /// The file holds API keys, so it is written 0600 and via a temporary file
    /// in the same directory: a crash mid-write leaves the old config rather
    /// than half a new one.
    static func write(_ changes: [String: String], to url: URL = path) throws {
        guard !changes.isEmpty else { return }
        try rewrite(url) { apply(changes, to: $0) }
    }

    /// Read, transform, and replace, keeping the file private throughout.
    ///
    /// Written once rather than twice: the scalar and list writers had the same
    /// directory creation, temporary file, permissions and atomic replace
    /// copied between them.
    private static func rewrite(_ url: URL, _ transform: (String) -> String) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = transform(existing)

        // A temporary in the same directory, so the replace is a rename rather
        // than a copy across volumes, and a crash leaves the old file intact.
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".config.yaml.\(UUID().uuidString)")
        try Data(updated.utf8).write(to: temporary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        let replaced = try manager.replaceItemAt(url, withItemAt: temporary) ?? url

        // Setting the mode on the temporary is not enough: replaceItemAt
        // preserves the *original* file's metadata, so an existing config that
        // was 0644 stayed 0644 and the tightening was silently discarded. The
        // file holds API keys, so the mode is set on the result too.
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replaced.path)
    }

    /// Rewrite the lines for `changes`, append anything the file lacks.
    static func apply(_ changes: [String: String], to text: String) -> String {
        var remaining = changes
        var output: [String] = []
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1

            guard
                let key = topLevelKey(in: line),
                let replacement = remaining.removeValue(forKey: key)
            else {
                output.append(line)
                continue
            }

            output.append("\(key): \(quoted(replacement))")
            // A wrapped value continues on the following indented lines; they
            // belonged to the old value and must go with it.
            while index < lines.count, isContinuation(Substring(lines[index])) {
                index += 1
            }
        }

        if !remaining.isEmpty {
            if output.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                output.append("")
            }
            for key in remaining.keys.sorted() {
                output.append("\(key): \(quoted(remaining[key] ?? ""))")
            }
            output.append("")
        }

        return output.joined(separator: "\n")
    }

    /// The key of a top-level `key: value` line, or nil for anything else.
    private static func topLevelKey(in line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon])
        guard
            !key.isEmpty,
            key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
        else { return nil }
        return key
    }

    /// Quote only where a bare scalar would parse as something else. Paths with
    /// spaces are fine bare, and quoting every value would churn the whole file
    /// on the first save.
    private static func quoted(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        let needsQuotes =
            value.contains(": ")
            || value.hasSuffix(":")
            || value.contains(" #")
            || value.hasPrefix("#")
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
            || value.hasPrefix("\"")
            || value.hasPrefix("'")
            || value.hasPrefix("[")
            || value.hasPrefix("{")
            || value.hasPrefix("&")
            || value.hasPrefix("*")
        guard needsQuotes else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Parsing

    /// Top-level `key: value` pairs only. Indented lines belong to a nested
    /// structure this does not model, so they are skipped rather than guessed
    /// at — except where they continue the previous value, which YAML allows
    /// and which is not optional to handle.
    ///
    /// A long path is wrapped by most YAML writers:
    ///
    ///     destination_directory: /Users/x/Library/.../60-69
    ///       Work & Career/62 Work files/Meetings
    ///
    /// YAML folds that into one value joined by a single space. Reading only
    /// the first line yields a path that exists nowhere and looks plausible,
    /// which is a far worse failure than reading nothing at all.
    static func scalars(in text: String) -> [String: String] {
        var values: [String: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1

            guard let first = line.first, !first.isWhitespace, first != "#" else { continue }
            guard let separator = line.firstIndex(of: ":") else { continue }

            let key = String(line[line.startIndex..<separator])
            var value = String(line[line.index(after: separator)...])

            while index < lines.count, isContinuation(lines[index]) {
                value += " " + lines[index].trimmingCharacters(in: .whitespaces)
                index += 1
            }

            guard let scalar = unwrap(value) else { continue }
            values[key] = scalar
        }
        return values
    }

    /// Turn the text after `key:` into its value.
    ///
    /// Quotes are resolved before comments, not after. A quoted value may
    /// legitimately contain " #" -- a Slack webhook or a path can -- and
    /// stripping the comment first truncated it at the hash, so what was
    /// written was not what came back.
    private static func unwrap(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return nil }

        if first == "\"" || first == "'" {
            var value = ""
            var escaped = false
            var closed = false
            for character in text.dropFirst() {
                if escaped {
                    value.append(character)
                    escaped = false
                } else if character == "\\", first == "\"" {
                    escaped = true
                } else if character == first {
                    closed = true
                    break
                } else {
                    value.append(character)
                }
            }
            // An unterminated quote is malformed; treating it as a bare scalar
            // at least keeps the rest of the file readable.
            guard closed else { return text.isEmpty ? nil : text }
            return value
        }

        // Bare scalar: a '#' only starts a comment when whitespace precedes it,
        // so a hash inside a path or a key stays part of the value.
        var value = text
        if let hash = value.range(of: " #") {
            value = String(value[value.startIndex..<hash.lowerBound])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Block sequences: a bare `key:` followed by indented `- item` lines.
    static func sequences(in text: String) -> [String: [String]] {
        var found: [String: [String]] = [:]
        let lines = text.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1
            guard
                let key = topLevelKey(in: line),
                line.drop(while: { $0 != ":" }).dropFirst()
                    .trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }

            var items: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                guard lines[index].first == " " || lines[index].first == "\t",
                    candidate.hasPrefix("- ")
                else { break }
                if let item = unwrap(String(candidate.dropFirst(2))) { items.append(item) }
                index += 1
            }
            if !items.isEmpty { found[key] = items }
        }
        return found
    }

    /// Replace a block sequence, or write one where the key is a bare scalar.
    static func applyList(_ key: String, _ items: [String], to text: String) -> String {
        var output: [String] = []
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var index = 0
        var written = false

        func rendered() -> [String] {
            items.isEmpty ? ["\(key): []"] : ["\(key):"] + items.map { "  - \(quoted($0))" }
        }

        while index < lines.count {
            let line = lines[index]
            index += 1
            guard topLevelKey(in: line) == key else {
                output.append(line)
                continue
            }
            output.append(contentsOf: rendered())
            written = true
            // Drop whatever the old value was, scalar or sequence.
            while index < lines.count {
                let next = lines[index]
                guard next.first == " " || next.first == "\t", !next.trimmingCharacters(in: .whitespaces).isEmpty
                else { break }
                index += 1
            }
        }

        if !written {
            if output.last?.trimmingCharacters(in: .whitespaces).isEmpty == false { output.append("") }
            output.append(contentsOf: rendered())
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    /// Write a list through to the file.
    static func writeList(_ key: String, _ items: [String], to url: URL = path) throws {
        try rewrite(url) { applyList(key, items, to: $0) }
    }

    /// An indented line that is neither a nested key nor a list item, so the
    /// only thing it can be is the rest of the value above it.
    private static func isContinuation(_ line: Substring) -> Bool {
        guard let first = line.first, first == " " || first == "\t" else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- ") else {
            return false
        }
        // `nested: value` is a mapping entry; `12:00 standup` is prose that
        // happens to contain a colon, so the space after it is what decides.
        if let colon = trimmed.firstIndex(of: ":") {
            let afterColon = trimmed[trimmed.index(after: colon)...]
            let key = trimmed[trimmed.startIndex..<colon]
            let looksLikeKey = !key.isEmpty && key.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "."
            }
            if looksLikeKey, afterColon.isEmpty || afterColon.first == " " { return false }
        }
        return true
    }
}
