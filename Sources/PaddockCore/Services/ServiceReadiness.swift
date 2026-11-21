import Darwin
import Foundation

/// One bounded check of whether a started service answers. Never takes longer than about a second.
enum ServiceReadiness {
    /// Whether the rendered probe target answers now.
    static func probe(_ readiness: Readiness, rendered target: String) -> Bool {
        switch readiness {
        case .tcp:
            guard let port = Int(target) else { return false }
            return PortCheck.acceptsIPv4(port: port)
        case .unixSocket:
            guard let fd = Wire.connect(to: target) else { return false }
            close(fd)
            return true
        case .http(_, let expectStatus):
            return httpStatus(target, timeout: 1) == expectStatus
        }
    }

    /// The status code a GET of a loopback `http://127.0.0.1:<port>/…` URL answers with, within `timeout`
    /// seconds in all; nil for any other URL or no answer.
    static func httpStatus(_ text: String, timeout: TimeInterval) -> Int? {
        guard let url = URLComponents(string: text), url.scheme == "http",
              url.host == "127.0.0.1" || url.host == "localhost", let port = url.port else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        func remaining() -> Int32 { Int32(max(0, deadline.timeIntervalSinceNow) * 1000) }
        guard let fd = PortCheck.openConnection(port: port, ipv6: false, timeout: remaining()) else { return nil }
        defer { close(fd) }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath)
            + (url.percentEncodedQuery.map { "?\($0)" } ?? "")
        var request = Array("GET \(path) HTTP/1.0\r\nHost: 127.0.0.1:\(port)\r\nUser-Agent: Paddock\r\n\r\n".utf8)
        while !request.isEmpty {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, remaining()) == 1 else { return nil }
            let n = write(fd, request, request.count)
            guard n > 0 else { return nil }
            request.removeFirst(n)
        }
        var response: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while response.count < 4096, !response.contains(UInt8(ascii: "\n")) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, remaining()) == 1 else { break }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            response += buffer[0..<n]
        }
        // `HTTP/1.1 200 OK`
        let line = String(decoding: response, as: UTF8.self).split(separator: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }
}
