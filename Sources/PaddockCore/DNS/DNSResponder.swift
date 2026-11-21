import Foundation
import Darwin

/// UDP DNS listener bound to 127.0.0.1 only; answers via `DNSMessage`.
public final class DNSResponder: @unchecked Sendable {
    public enum Failure: Error { case socket(Int32), bind(Int32) }

    public let port: Int
    private let tld: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var thread: Thread?

    public init(port: Int, tld: String) {
        self.port = port
        self.tld = tld
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { return }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw Failure.socket(errno) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { let e = errno; close(s); throw Failure.bind(e) }
        // Wake periodically so the loop notices stop() even if close doesn't unblock recvfrom.
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        let tld = self.tld
        let t = Thread { [weak self] in self?.loop(socket: s, tld: tld) }
        t.name = "app.paddock.dns"
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock()
        let s = fd
        fd = -1
        thread = nil
        lock.unlock()
        if s >= 0 { shutdown(s, SHUT_RDWR); close(s) }
    }

    private func isRunning(_ s: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fd == s
    }

    private func loop(socket s: Int32, tld: String) {
        var buf = [UInt8](repeating: 0, count: 1500)
        while isRunning(s) {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(s, &buf, buf.count, 0, $0, &fromLen)
                }
            }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR || errno == EWOULDBLOCK { continue }
                return
            }
            guard let reply = DNSMessage.response(to: Data(buf[0..<n]), tld: tld) else { continue }
            _ = reply.withUnsafeBytes { raw in
                withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(s, raw.baseAddress, raw.count, 0, $0, fromLen)
                    }
                }
            }
        }
    }
}
