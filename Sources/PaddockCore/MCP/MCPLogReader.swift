import Darwin
import Foundation

/// Reads the end of one log for `paddock mcp`. Never writes.
enum MCPLogReader {
    /// The last `count` complete lines of a regular file, read from its last `LogTail.tailBytes` and cleaned as
    /// the Logs window cleans them; with `containing`, only the lines that mention it (any case). The file is
    /// opened without following a symlink, which could name any file. Nil when it can't be opened that way.
    static func lastLines(of url: URL, count: Int, containing: String?) -> [String]? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = UInt64(max(0, info.st_size))
        let start = size > LogTail.tailBytes ? size - LogTail.tailBytes : 0
        guard size > start else { return [] }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return nil }

        var bytes = data[...]
        // Starting in the middle of a file, the first line is the tail of one: dropped.
        if start > 0 {
            guard let newline = bytes.firstIndex(of: 0x0A) else { return [] }
            bytes = bytes[bytes.index(after: newline)...]
        }
        var lines = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map { LogTail.clean(String($0)) }
        if lines.last == "" { lines.removeLast() }
        if let containing, !containing.isEmpty {
            lines = lines.filter { $0.localizedCaseInsensitiveContains(containing) }
        }
        return Array(lines.suffix(max(0, count)))
    }
}
