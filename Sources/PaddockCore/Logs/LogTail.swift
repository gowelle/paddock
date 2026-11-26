import Foundation

/// Where a log was last read to, and which file that was (a rotated log is another file under the same name).
public struct LogPosition: Equatable, Sendable {
    public let offset: UInt64
    public let file: UInt64

    public init(offset: UInt64, file: UInt64) {
        self.offset = offset
        self.file = file
    }
}

/// What one read of a log gave.
public struct LogChunk: Equatable, Sendable {
    /// The complete lines read, oldest first, without their line ends.
    public let lines: [String]
    /// Where to read from next; nil when the file can't be read (it may appear later).
    public let position: LogPosition?
    /// True when this read started over (the first read, a rotated or cut-down file): what was shown before
    /// no longer precedes these lines.
    public let restarted: Bool

    public init(lines: [String], position: LogPosition?, restarted: Bool) {
        self.lines = lines
        self.position = position
        self.restarted = restarted
    }
}

/// Reads the end of a log and, after that, only what was added to it. Never writes.
public enum LogTail {
    /// How much of a file's end the first read (and a read after a long pause) takes.
    public static let tailBytes: UInt64 = 256 * 1024

    /// The lines added after `position`. With no position, with another file under the name (rotated), with
    /// a file now shorter than the position (cut down), or with more than `tailBytes` added, it starts over
    /// from the last `tailBytes`. A last line still being written is left for the next read.
    public static func read(_ url: URL, after position: LogPosition?) -> LogChunk {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return LogChunk(lines: [], position: nil, restarted: position != nil)
        }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return LogChunk(lines: [], position: nil, restarted: position != nil)
        }
        let size = UInt64(max(0, info.st_size))
        let file = UInt64(info.st_ino)

        var start = position?.offset ?? 0
        var restarted = false
        if position == nil || position?.file != file || size < start || size - start > tailBytes {
            restarted = true
            start = size > tailBytes ? size - tailBytes : 0
        }
        guard size > start else {
            return LogChunk(lines: [], position: LogPosition(offset: start, file: file), restarted: restarted)
        }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty else {
            return LogChunk(lines: [], position: LogPosition(offset: start, file: file), restarted: restarted)
        }

        var bytes = data[...]
        var consumed = UInt64(data.count)
        // Starting in the middle of a file, the first line is the tail of one: dropped.
        if restarted, start > 0 {
            guard let newline = bytes.firstIndex(of: 0x0A) else {
                return LogChunk(lines: [], position: LogPosition(offset: start + consumed, file: file), restarted: true)
            }
            bytes = bytes[bytes.index(after: newline)...]
        }
        // A line with no end yet is still being written: left for next time (unless it alone is very long).
        if let last = bytes.last, last != 0x0A {
            if let newline = bytes.lastIndex(of: 0x0A) {
                consumed -= UInt64(bytes.distance(from: newline, to: bytes.endIndex) - 1)
                bytes = bytes[...newline]
            } else if UInt64(bytes.count) < tailBytes / 4 {
                consumed -= UInt64(bytes.count)
                bytes = bytes[bytes.endIndex...]
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { clean(String($0)) }
        if text.hasSuffix("\n") { lines.removeLast() }
        return LogChunk(lines: lines, position: LogPosition(offset: start + consumed, file: file), restarted: restarted)
    }

    /// A line as it is shown: without a carriage return, terminal colour and cursor sequences, or other
    /// control characters (a tab becomes spaces).
    static func clean(_ line: String) -> String {
        var text = line
        if text.contains("\u{1B}") {
            text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return text }
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                kept.append(contentsOf: "    ".unicodeScalars)
            } else if scalar.value >= 0x20, scalar.value != 0x7F {
                kept.append(scalar)
            }
        }
        return String(kept)
    }
}

/// One thing a log says: a line, or for a Laravel log an entry with what follows it (its stack trace).
public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: Int
    /// The first line.
    public let text: String
    /// `ERROR`, `INFO`…: a Laravel (Monolog) entry's level; nil for any other line.
    public let level: String?
    /// The lines that belong to it: a stack trace, a multi-line message.
    public var detail: [String]

    public init(id: Int, text: String, level: String? = nil, detail: [String] = []) {
        self.id = id
        self.text = text
        self.level = level
        self.detail = detail
    }

    /// True for the levels that mean something went wrong.
    public var isProblem: Bool {
        guard let level else { return false }
        return ["ERROR", "CRITICAL", "ALERT", "EMERGENCY"].contains(level)
    }

    public var isWarning: Bool { level == "WARNING" }

    /// Whether the entry, its level or anything under it mentions `filter` (any case).
    public func matches(_ filter: String) -> Bool {
        text.localizedCaseInsensitiveContains(filter) || detail.contains { $0.localizedCaseInsensitiveContains(filter) }
    }
}

/// Turns lines into entries. A line that opens an entry begins one, with its level where the format has one:
/// Laravel (Monolog), PHP's error log and PHP-FPM, PostgreSQL, MySQL's error log, and Caddy's JSON. The lines
/// after it that belong to it (a stack trace, a query and its hint) are its detail. In a log Paddock doesn't
/// know, every line is an entry of its own.
public struct LogParser: Sendable {
    /// How many lines one entry keeps under it; a longer trace ends with a line saying how many were left out.
    public static let detailLimit = 300

    private var nextID = 0
    private var omitted = 0
    /// The entry last added takes the lines that follow it as detail (it opened a structured entry).
    private var lastTakesDetail = false

    public init() {}

    private static let laravel = try! NSRegularExpression(
        pattern: #"^\[\d{4}-\d{2}-\d{2}[T ][0-9:.+\-Z]+\] [A-Za-z0-9_\-]+\.([A-Z]+): "#)
    /// PHP's and PHP-FPM's date, with an optional timezone: `[26-Nov-2026 10:14:10 UTC] `.
    private static let phpDate = try! NSRegularExpression(
        pattern: #"^\[\d{1,2}-[A-Z][a-z]{2}-\d{4} \d{2}:\d{2}:\d{2}(?: [A-Z]{2,5})?\] "#)
    /// What follows PHP's date: `PHP Warning: `, `Fatal error: `, or an FPM severity.
    private static let phpError = try! NSRegularExpression(
        pattern: #"^PHP ((?:Fatal|Parse|Recoverable fatal) error|Warning|Notice|Deprecated|Strict Standards): "#)
    private static let fpmSeverity = try! NSRegularExpression(
        pattern: #"^(DEBUG|NOTICE|WARNING|ERROR|ALERT|CRITICAL|EMERGENCY): "#)
    /// `2026-11-26 10:14:10.123 UTC [1234] ERROR: `, with any `log_line_prefix` timezone node.
    private static let postgres = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?(?: [A-Z]{2,5})? \[\d+\] (DEBUG[1-5]|INFO|NOTICE|WARNING|ERROR|LOG|FATAL|PANIC): "#)
    /// `2026-11-26T10:14:10.123456Z 12 [ERROR] [MY-000067] [Server] `.
    private static let mysql = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})? +\d+ \[(ERROR|Warning|Note|System)\]"#)
    /// A Caddy JSON line longer than this is shown as it is rather than parsed.
    private static let jsonLimit = 64 * 1024

    /// An entry a line opens: what it says, its level where the format has one, any fields the format keeps
    /// apart, and whether the lines after it belong to it.
    struct Opening {
        var text: String
        var level: String?
        var detail: [String] = []
        var takesDetail: Bool
    }

    /// The entry `line` opens, or nil when it opens none (it is a plain line, or detail of the entry above).
    static func opening(of line: String) -> Opening? {
        if let level = laravelLevel(of: line) {
            return Opening(text: line, level: level, takesDetail: true)
        }
        if let opening = phpOpening(of: line) { return opening }
        if let opening = postgresOpening(of: line) { return opening }
        if let opening = mysqlOpening(of: line) { return opening }
        if let opening = caddyOpening(of: line) { return opening }
        return nil
    }

    /// The level a line opens a Laravel entry with, if it does.
    static func level(of line: String) -> String? { laravelLevel(of: line) }

    private static func laravelLevel(of line: String) -> String? {
        guard line.hasPrefix("[") else { return nil }
        return capture(laravel, at: 1, in: line)
    }

    /// PHP's error log (`PHP Warning: …`) and PHP-FPM (`WARNING: …`), both under PHP's date; and the FPM
    /// slowlog, whose header (`[pool www] pid 1234`) has no level but still opens an entry.
    private static func phpOpening(of line: String) -> Opening? {
        guard let date = match(phpDate, line), date.range.location == 0,
              let text = substring(line, from: date.range.upperBound) else { return nil }
        let level: String?
        if let error = capture(phpError, at: 1, in: text) {
            level = phpLevel(error)
        } else if let severity = capture(fpmSeverity, at: 1, in: text) {
            level = normalizedSeverity(severity)
        } else {
            level = nil
        }
        // Everything under PHP's date is one message: it starts an entry whether or not it names a level.
        return Opening(text: line, level: level, takesDetail: true)
    }

    private static func postgresOpening(of line: String) -> Opening? {
        guard let raw = capture(postgres, at: 1, in: line) else { return nil }
        return Opening(text: line, level: normalizedSeverity(raw), takesDetail: true)
    }

    private static func mysqlOpening(of line: String) -> Opening? {
        guard let raw = capture(mysql, at: 1, in: line) else { return nil }
        let level: String
        switch raw {
        case "ERROR": level = "ERROR"
        case "Warning": level = "WARNING"
        default: level = "INFO"
        }
        return Opening(text: line, level: level, takesDetail: false)
    }

    /// Caddy logs JSON: the entry is its `msg`, its level is `level`, and the other fields that are not
    /// objects (the logger, the error) sit folded under it.
    private static func caddyOpening(of line: String) -> Opening? {
        guard line.hasPrefix("{"), line.utf8.count <= jsonLimit,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let raw = object["level"] as? String else { return nil }
        let fields = object.keys.sorted().compactMap { key -> String? in
            guard key != "level", key != "msg", key != "ts", let value = scalar(object[key]) else { return nil }
            return "\(key)=\(value)"
        }
        return Opening(text: object["msg"] as? String ?? line, level: caddyLevel(raw),
                       detail: fields.isEmpty ? [] : [fields.joined(separator: " ")], takesDetail: false)
    }

    /// A JSON value as it is shown under a Caddy entry: strings as they are, numbers and booleans as text,
    /// anything else left out.
    private static func scalar(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func phpLevel(_ raw: String) -> String {
        switch raw {
        case "Fatal error", "Parse error", "Recoverable fatal error": return "ERROR"
        case "Warning": return "WARNING"
        default: return "NOTICE"
        }
    }

    /// The uppercase level a format names, in the words the window knows: PostgreSQL's `LOG` is ordinary
    /// information, its `FATAL` and `PANIC` are critical, and a debug level is just `DEBUG`.
    private static func normalizedSeverity(_ raw: String) -> String {
        switch raw {
        case "LOG": return "INFO"
        case "FATAL", "PANIC": return "CRITICAL"
        default: return raw.hasPrefix("DEBUG") ? "DEBUG" : raw
        }
    }

    private static func caddyLevel(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "error": return "ERROR"
        case "warn", "warning": return "WARNING"
        case "info": return "INFO"
        case "debug": return "DEBUG"
        case "fatal", "panic": return "CRITICAL"
        default: return raw.uppercased()
        }
    }

    // MARK: - Matching

    private static func match(_ expression: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }

    private static func capture(_ expression: NSRegularExpression, at group: Int, in text: String) -> String? {
        guard let result = match(expression, text),
              let range = Range(result.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func substring(_ text: String, from offset: Int) -> String? {
        guard let index = text.utf16.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex),
              let start = String.Index(index, within: text) else { return nil }
        return String(text[start...])
    }

    /// Adds `lines` to `entries`, continuing the last entry when they belong to it.
    public mutating func append(_ lines: [String], to entries: inout [LogEntry]) {
        for line in lines {
            if let opening = Self.opening(of: line) {
                entries.append(LogEntry(id: nextID, text: opening.text, level: opening.level, detail: opening.detail))
                nextID += 1
                omitted = 0
                lastTakesDetail = opening.takesDetail
            } else if lastTakesDetail, let last = entries.indices.last {
                if entries[last].detail.count < Self.detailLimit {
                    entries[last].detail.append(line)
                } else {
                    omitted += 1
                    let note = omitted == 1 ? "(1 more line)" : "(\(omitted) more lines)"
                    if omitted == 1 { entries[last].detail.append(note) } else { entries[last].detail[Self.detailLimit] = note }
                }
            } else {
                entries.append(LogEntry(id: nextID, text: line))
                nextID += 1
                omitted = 0
                lastTakesDetail = false
            }
        }
    }
}
