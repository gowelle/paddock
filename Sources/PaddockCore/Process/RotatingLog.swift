import Darwin
import Foundation

/// A process's log that Paddock writes itself (a `ProcessOutput`): what the process prints arrives on a pipe and
/// is appended to `url`; once the next write would take the file past `limit` bytes, the file becomes
/// `<url>.1` (replacing the previous one) and a new one starts. So the log and its one previous file are each at
/// most `limit` bytes.
///
/// Each attached pipe is read on its own thread one chunk at a time, and a chunk is written before the next is
/// read: a process that prints faster than the disk takes it blocks on its full pipe. The daemon never holds
/// more than one chunk per pipe, however much a process prints.
public final class RotatingLog: ProcessOutput, @unchecked Sendable {
    public let url: URL
    public let limit: UInt64
    /// The most a reader holds at once.
    public static let chunkSize = 64 * 1024

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var size: UInt64 = 0
    private var pending = 0
    private var peak = 0
    /// Tests hold the writer back to show the process is held back too.
    private var paused = false
    private let resumed = NSCondition()

    public init(url: URL, limit: UInt64) {
        self.url = url
        self.limit = limit
    }

    deinit { if fd >= 0 { close(fd) } }

    /// The most bytes ever read from a pipe and not yet written.
    public var peakPendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    public func attach(_ fd: Int32) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
            while true {
                waitWhilePaused()
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                setPending(n)
                buffer.withUnsafeBytes { write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                setPending(0)
            }
            close(fd)
        }
        thread.name = "app.paddock.log.\(url.lastPathComponent)"
        thread.start()
    }

    /// A line of Paddock's own (or any text), through the same rotation.
    public func append(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { write($0) }
    }

    /// Closes the current file (a later write opens it again).
    public func closeFile() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
    }

    func pauseForTesting(_ pause: Bool) {
        resumed.lock()
        paused = pause
        resumed.broadcast()
        resumed.unlock()
    }

    private func waitWhilePaused() {
        resumed.lock()
        while paused { resumed.wait() }
        resumed.unlock()
    }

    private func setPending(_ n: Int) {
        lock.lock()
        pending = n
        peak = max(peak, n)
        lock.unlock()
    }

    private func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if fd < 0 { openLocked(truncating: false) }
        if size > 0, size + UInt64(bytes.count) > limit {
            if fd >= 0 { close(fd) }
            let previous = url.appendingPathExtension("1")
            Darwin.rename(url.path, previous.path)
            openLocked(truncating: true)
        }
        guard fd >= 0 else { return }
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                return // A full disk or a removed folder: the line is lost, the process carries on.
            }
            offset += n
        }
        size += UInt64(bytes.count)
    }

    private func openLocked(truncating: Bool) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | (truncating ? O_TRUNC : 0), 0o644)
        var info = stat()
        size = fd >= 0 && fstat(fd, &info) == 0 ? UInt64(info.st_size) : 0
    }
}
