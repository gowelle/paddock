import CryptoKit
import Darwin
import Foundation
import Network
import Security

/// A tiny HTTP and websocket server on 127.0.0.1 for the proxy tests. A plain request is answered with
/// `echo <path?query> host=<Host> forwarded-for=<X-Forwarded-For>`; a websocket upgrade is accepted and every
/// text frame is sent back.
final class EchoServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private var stopped = false
    private let lock = NSLock()

    init(port: Int) throws {
        self.port = port
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        listener = fd
        Thread { [self] in acceptLoop() }.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop() {
        while !isStopped {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { if isStopped { return } else { continue } }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var head = Data()
        var byte: UInt8 = 0
        while !(head.count >= 4 && head.suffix(4) == Data("\r\n\r\n".utf8)) {
            guard read(fd, &byte, 1) == 1 else { return }
            head.append(byte)
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            send(fd, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                 + "Sec-WebSocket-Accept: \(accept)\r\n\r\n")
            while let (opcode, payload) = WebSocketFrame.read(fd) {
                if opcode == 0x8 { _ = WebSocketFrame.write(fd, opcode: 0x8, payload: Data(), masked: false); return }
                guard WebSocketFrame.write(fd, opcode: opcode, payload: payload, masked: false) else { return }
            }
            return
        }
        let body = "echo \(target) host=\(headers["host"] ?? "") forwarded-for=\(headers["x-forwarded-for"] ?? "")"
        send(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n"
             + "Connection: close\r\n\r\n\(body)")
    }

    private func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    }
}

/// Reading and writing single websocket frames (payloads under 64 KB) on a blocking descriptor.
enum WebSocketFrame {
    static func read(_ fd: Int32) -> (UInt8, Data)? {
        guard let head = exactly(fd, 2) else { return nil }
        let opcode = head[0] & 0x0F
        let masked = head[1] & 0x80 != 0
        var length = Int(head[1] & 0x7F)
        if length == 126 {
            guard let ext = exactly(fd, 2) else { return nil }
            length = Int(ext[0]) << 8 | Int(ext[1])
        } else if length == 127 {
            return nil
        }
        let mask = masked ? exactly(fd, 4) : Data([0, 0, 0, 0])
        guard let mask, var payload = exactly(fd, length) else { return nil }
        for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
        return (opcode, payload)
    }

    @discardableResult
    static func write(_ fd: Int32, opcode: UInt8, payload: Data, masked: Bool) -> Bool {
        var frame = Data([0x80 | opcode])
        let lengthByte: UInt8 = masked ? 0x80 : 0
        if payload.count < 126 {
            frame.append(lengthByte | UInt8(payload.count))
        } else {
            frame.append(lengthByte | 126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        }
        var body = payload
        if masked {
            let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
            frame.append(contentsOf: mask)
            for i in 0..<body.count { body[i] ^= mask[i % 4] }
        }
        frame.append(body)
        return frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) } == frame.count
    }

    static func exactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: max(1, count))
        while data.count < count {
            let n = Darwin.read(fd, &buffer, count - data.count)
            guard n > 0 else { return nil }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }
}

/// A websocket round trip through TLS to 127.0.0.1:<port>, presenting `host` (SNI and Host header) and trusting
/// only `root`: the upgrade's status line, and the text the server sent back for `message`.
enum WebSocketProbe {
    static func roundTrip(host: String, port: Int, path: String, root: URL, message: String,
                          timeout: TimeInterval = 15) throws -> (status: String, echo: String?) {
        let pem = try String(contentsOf: root, encoding: .utf8)
        let base64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64), let anchor = SecCertificateCreateWithData(nil, der as CFData) else {
            throw POSIXError(.EINVAL)
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetAnchorCertificates(secTrust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(secTrust, true)
            SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, host as CFString))
            complete(SecTrustEvaluateWithError(secTrust, nil))
        }, DispatchQueue.global())
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!,
                                      using: NWParameters(tls: tls))
        let queue = DispatchQueue(label: "pdk.ws.probe")
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error), .waiting(let error): failure = error; ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        guard ready.wait(timeout: .now() + timeout) == .success, failure == nil else {
            throw failure ?? POSIXError(.ETIMEDOUT)
        }
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try send(connection, Data(request.utf8), timeout: timeout)
        var buffer = Data()
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            buffer.append(try receive(connection, timeout: timeout))
        }
        let end = buffer.range(of: Data("\r\n\r\n".utf8))!
        let status = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        buffer = Data(buffer[end.upperBound...])
        guard status.contains(" 101 ") else { return (status, nil) }
        var frame = Data([0x81, 0x80 | UInt8(message.utf8.count)])
        let mask: [UInt8] = [1, 2, 3, 4]
        frame.append(contentsOf: mask)
        frame.append(contentsOf: Array(message.utf8).enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try send(connection, frame, timeout: timeout)
        while buffer.count < 2 || buffer.count < 2 + Int(buffer[buffer.startIndex + 1] & 0x7F) {
            buffer.append(try receive(connection, timeout: timeout))
        }
        let length = Int(buffer[buffer.startIndex + 1] & 0x7F)
        let payload = buffer[(buffer.startIndex + 2)..<(buffer.startIndex + 2 + length)]
        return (status, String(decoding: payload, as: UTF8.self))
    }

    private static func send(_ connection: NWConnection, _ data: Data, timeout: TimeInterval) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.send(content: data, completion: .contentProcessed { error in failure = error; done.signal() })
        guard done.wait(timeout: .now() + timeout) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let failure { throw failure }
    }

    private static func receive(_ connection: NWConnection, timeout: TimeInterval) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        var failure: Error?
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            result = data
            failure = error ?? (isComplete && (data?.isEmpty ?? true) ? POSIXError(.ECONNRESET) : nil)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let failure { throw failure }
        return result ?? Data()
    }
}
