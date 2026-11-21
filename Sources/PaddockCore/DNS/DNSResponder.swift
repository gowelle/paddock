import Foundation
import Darwin

/// UDP DNS listener bound to 127.0.0.1 only; answers via `DNSMessage`.
public final class DNSResponder: @unchecked Sendable {
    public enum Failure: Error { case socket(Int32), bind(Int32) }

    public let port: Int
    private let tld: String
    private final class Run: @unchecked Sendable {
        let lock = NSLock()
        private var stopped = false
        let done = DispatchSemaphore(value: 0)
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
    }

    private let lock = NSLock()
    private var run: Run?

    public init(port: Int, tld: String) {
        self.port = port
        self.tld = tld
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard run == nil else { return }
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
        let r = Run()
        run = r
        let tld = self.tld
        let t = Thread { [self] in
            loop(socket: s, tld: tld, run: r)
            close(s)               // only the loop thread closes its own socket
            r.done.signal()
        }
        t.name = "app.paddock.dns"
        t.start()
    }

    /// Signals the loop to exit and waits (at most ~one receive timeout) so the port is free on return.
    public func stop() {
        lock.lock()
        let r = run
        run = nil
        lock.unlock()
        guard let r else { return }
        r.stop()
        _ = r.done.wait(timeout: .now() + 1)
    }

    private func loop(socket s: Int32, tld: String, run: Run) {
        var buf = [UInt8](repeating: 0, count: 1500)
        while !run.isStopped {
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
