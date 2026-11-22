import Darwin
import Foundation

/// Reads the end of one log for `paddock mcp`. Never writes.
enum MCPLogReader {
    struct Tail: Equatable {
        /// Oldest first, cleaned as the Logs window cleans them.
        var lines: [String]
        /// The first line is only the end of a longer one.
        var cut: Bool
    }

    /// The last `count` complete lines of a regular file, read from its last `LogTail.tailBytes`; with
    /// `containing`, only the lines that mention it (any case).
    ///
    /// The file is opened without following a symlink, which could name any file. With `root` (a site's
    /// folder), the file that was opened must also really be inside it: a site whose `storage/logs` is a link to
    /// somewhere else on the Mac is not a way to read what is there. That is asked of the open file itself, so
    /// nothing can be swapped between the check and the read. Nil when it can't be opened under those rules.
    static func tail(of url: URL, count: Int, containing: String?, inside root: URL? = nil) -> Tail? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        if let root {
            guard let opened = path(of: fd), let real = realPath(root.path),
                  opened.hasPrefix(real.hasSuffix("/") ? real : real + "/") else { return nil }
        }
        let size = UInt64(max(0, info.st_size))
        let start = size > LogTail.tailBytes ? size - LogTail.tailBytes : 0
        guard size > start else { return Tail(lines: [], cut: false) }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return nil }

        var bytes = data[...]
        var cut = false
        // Starting in the middle of a file, the first line is the tail of one: dropped, unless it is all there is.
        if start > 0 {
            if let newline = bytes.firstIndex(of: 0x0A), bytes.index(after: newline) < bytes.endIndex {
                bytes = bytes[bytes.index(after: newline)...]
            } else {
                cut = true
                // Not from the middle of a character.
                while let first = bytes.first, first & 0xC0 == 0x80 { bytes = bytes.dropFirst() }
            }
        }
        var lines = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map { LogTail.clean(String($0)) }
        if lines.last == "" { lines.removeLast() }
        if let containing, !containing.isEmpty {
            lines = lines.filter { $0.localizedCaseInsensitiveContains(containing) }
        }
        return Tail(lines: Array(lines.suffix(max(0, count))), cut: cut && lines.count <= count)
    }

    /// `text`, or its start when it is more than `limit` bytes of UTF-8 (never part of a character's bytes).
    static func clipped(_ text: String, toBytes limit: Int) -> String? {
        guard text.utf8.count > limit else { return nil }
        var kept = String.UnicodeScalarView(), size = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            if size + width > limit { break }
            kept.append(scalar)
            size += width
        }
        return String(kept)
    }

    /// Where an open file really is.
    private static func path(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        // The same form F_GETPATH answers in.
        let fd = open(resolved, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return String(cString: resolved) }
        defer { close(fd) }
        return self.path(of: fd) ?? String(cString: resolved)
    }
}
