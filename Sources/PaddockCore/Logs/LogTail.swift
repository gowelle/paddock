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

/// Turns lines into entries. A line that starts a Laravel entry (`[2026-11-22 10:14:10] local.ERROR: …`)
/// begins one with its level; the lines after it, up to the next such line, are its detail. In a log with no
/// such lines every line is an entry of its own.
public struct LogParser: Sendable {
    /// How many lines one entry keeps under it; a longer trace ends with a line saying how many were left out.
    public static let detailLimit = 300

    private var nextID = 0
    private var omitted = 0

    public init() {}

    private static let header = try! NSRegularExpression(
        pattern: #"^\[\d{4}-\d{2}-\d{2}[T ][0-9:.+\-Z]+\] [A-Za-z0-9_\-]+\.([A-Z]+): "#)

    /// The level a line opens a Laravel entry with, if it does.
    static func level(of line: String) -> String? {
        guard line.hasPrefix("[") else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = header.firstMatch(in: line, range: range), let level = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[level])
    }

    /// Adds `lines` to `entries`, continuing the last entry when they belong to it.
    public mutating func append(_ lines: [String], to entries: inout [LogEntry]) {
        for line in lines {
            if let level = Self.level(of: line) {
                entries.append(LogEntry(id: nextID, text: line, level: level))
                nextID += 1
                omitted = 0
            } else if let last = entries.indices.last, entries[last].level != nil {
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
            }
        }
    }
}
