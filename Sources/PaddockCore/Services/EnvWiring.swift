import Foundation

/// Merges a service's `.env` lines into a site's `.env` text. The keys the service defines are updated where
/// they already appear and appended where they don't; every other byte is left as it was.
public enum EnvWiring {
    public struct Result: Equatable, Sendable {
        /// The whole new file.
        public let text: String
        /// Every key the service defines, each once, in the service's order.
        public let settings: [String]
        /// Keys the file lacked, in the service's order.
        public let added: [String]
        /// Keys whose line changed, in the service's order.
        public let updated: [String]
    }

    public static func merge(existing: String, service lines: [String]) -> Result {
        let service = parsed(lines)
        guard !service.keys.isEmpty else {
            return Result(text: existing, settings: [], added: [], updated: [])
        }
        let newline = appendedNewline(of: existing)
        var lines = splitLines(existing)
        let endsWithNewline = lines.last.map { !$0.terminator.isEmpty } ?? false

        var present: Set<String> = []
        var changed: Set<String> = []
        for index in lines.indices {
            let original = lines[index].line
            var line = original
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let found = setting(line), let value = service.values[found.key] else { continue }
            present.insert(found.key)
            let replacement = "\(found.key)=\(value)"
            if replacement != original {
                lines[index].line = replacement
                changed.insert(found.key)
            }
        }

        var text = lines.map { $0.line + $0.terminator }.joined()
        let added = service.keys.filter { !present.contains($0) }
        if !added.isEmpty {
            let block = added.map { "\($0)=\(service.values[$0] ?? "")" }.joined(separator: newline)
            if text.isEmpty {
                text = block
            } else if endsWithNewline {
                text += block + newline
            } else {
                text += newline + block
            }
        }
        return Result(text: text, settings: service.keys, added: added,
                      updated: service.keys.filter { changed.contains($0) })
    }

    /// The text's lines, each with the terminator it had (`\n`, `\r\n`, or none on an unterminated last
    /// line). Scanned by Unicode scalar: `String.split(separator: "\n")` never matches, because `"\r\n"` is
    /// one grapheme cluster in a String.
    private static func splitLines(_ text: String) -> [(line: String, terminator: String)] {
        let scalars = Array(text.unicodeScalars)
        var lines: [(line: String, terminator: String)] = []
        var current = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\n" {
                lines.append((String(current), "\n"))
                current = String.UnicodeScalarView()
            } else if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
                lines.append((String(current), "\r\n"))
                current = String.UnicodeScalarView()
                index += 1
            } else {
                current.append(scalar)
            }
            index += 1
        }
        if !current.isEmpty { lines.append((String(current), "")) }
        return lines
    }

    /// The service's settings: comments, blanks and non-settings ignored; a repeated key keeps its first
    /// position and its last value.
    private static func parsed(_ lines: [String]) -> (keys: [String], values: [String: String]) {
        var keys: [String] = []
        var values: [String: String] = [:]
        for line in lines {
            guard let found = setting(line) else { continue }
            if values[found.key] == nil { keys.append(found.key) }
            values[found.key] = found.value
        }
        return (keys, values)
    }

    /// `KEY=value`, with `KEY` matching `[A-Za-z_][A-Za-z0-9_]*` and the value everything after the first `=`.
    private static func setting(_ line: String) -> (key: String, value: String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<equals])
        guard isKey(key) else { return nil }
        return (key, String(line[line.index(after: equals)...]))
    }

    private static func isKey(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return key.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// `\r\n` when every line the file terminates ends with `\r\n`; `\n` otherwise.
    private static func appendedNewline(of text: String) -> String {
        let terminated = splitLines(text).filter { !$0.terminator.isEmpty }
        return !terminated.isEmpty && terminated.allSatisfy { $0.terminator == "\r\n" } ? "\r\n" : "\n"
    }
}
