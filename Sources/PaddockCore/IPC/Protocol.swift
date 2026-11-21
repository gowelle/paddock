import Foundation

/// A request from a client (CLI or menu bar app) to the daemon.
public enum Request: Codable, Equatable, Sendable {
    case status, start, stop, restart
    case park(path: String), forget(path: String)
    case link(name: String, path: String), unlink(name: String)
    case secure(site: String), unsecure(site: String)
    case isolate(site: String, version: PHPVersion), unisolate(site: String)
    case use(version: PHPVersion)
    case installPHP(version: PHPVersion), removePHP(version: PHPVersion)
    case trust
    case shutdown
}

public enum Response: Codable, Equatable, Sendable {
    case ok(EngineStatus)
    case error(code: String, message: String)
}

/// The `code` values of `Response.error`.
public enum ErrorCode {
    public static let unknownSite = "unknown_site"
    public static let notADirectory = "not_a_directory"
    public static let phpNotInstalled = "php_not_installed"
    public static let phpInUse = "php_in_use"
    public static let phpNotAvailable = "php_not_available"
    public static let portsBlocked = "ports_blocked"
    /// A site is served over HTTPS but macOS does not trust Paddock's certificate authority.
    public static let needsTrust = "needs_trust"
    public static let trustDisabled = "trust_disabled"
    public static let `internal` = "internal"
}

/// Wire format: one JSON value per line, in each direction.
enum Wire {
    /// Largest request the server reads, in bytes.
    static let maxRequestBytes = 64 * 1024
    /// Largest response the client reads, in bytes.
    static let maxResponseBytes = 4 * 1024 * 1024

    static func socketAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // sun_path is 104 bytes on macOS, including the terminating NUL.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Connects a new unix stream socket to `path`; nil on failure with errno set.
    static func connect(to path: String) -> Int32? {
        guard var addr = socketAddress(path) else { errno = ENAMETOOLONG; return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let saved = errno
            close(fd)
            errno = saved
            return nil
        }
        return fd
    }

    static func setTimeout(_ fd: Int32, seconds: TimeInterval) {
        let whole = Int(seconds)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    enum ReadResult {
        case line(Data)
        case tooLarge
        case closed
        case timedOut
    }

    /// Reads up to and excluding the first newline, giving up after `limit` bytes.
    static func readLine(_ fd: Int32, limit: Int) -> ReadResult {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .closed
            }
            if n == 0 { return data.isEmpty ? .closed : .line(data) }
            if let newline = buffer[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[0..<newline])
                return data.count > limit ? .tooLarge : .line(data)
            }
            data.append(contentsOf: buffer[0..<n])
            if data.count > limit { return .tooLarge }
        }
    }

    /// Writes everything, newline-terminated. False if the peer is gone or too slow.
    @discardableResult
    static func writeLine(_ fd: Int32, _ payload: Data) -> Bool {
        let bytes = [UInt8](payload) + [UInt8(ascii: "\n")]
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }
}
