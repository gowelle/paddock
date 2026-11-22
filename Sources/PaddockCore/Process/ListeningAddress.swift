import Foundation

/// A TCP listening address as `lsof -F n` names it (`127.0.0.1:8080`, `*:3000`, `[::1]:6001`), for site tasks'
/// listening warning. (Services keep their own, stricter `ServiceManager.isLoopback`: 127.0.0.1 and [::1] only.)
public struct ListeningAddress: Equatable, Sendable {
    /// As `lsof` wrote it: `*`, `0.0.0.0`, `127.0.0.1`, `[::]`, `[fe80::1]`…
    public let host: String
    /// Nil when it isn't a port number above 0.
    public let port: Int?

    public init(host: String, port: Int?) {
        self.host = host
        self.port = port
    }

    /// Nil for text that isn't `host:port`.
    public init?(_ text: String) {
        guard let colon = text.lastIndex(of: ":"), colon != text.startIndex else { return nil }
        host = String(text[..<colon])
        guard let number = Int(text[text.index(after: colon)...]) else { return nil }
        port = number > 0 ? number : nil
    }

    /// Only this Mac can reach it: anywhere in 127.0.0.0/8, or ::1.
    public var isLoopback: Bool {
        if host == "[::1]" || host == "::1" { return true }
        // An IPv4-mapped IPv6 address (::ffff:127.0.0.1) is its IPv4 address.
        var v4 = host
        for prefix in ["[::ffff:", "::ffff:"] where host.lowercased().hasPrefix(prefix) {
            v4 = String(host.dropFirst(prefix.count))
            if v4.hasSuffix("]") { v4.removeLast() }
            break
        }
        let parts = v4.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "127"
    }

    /// Every interface: `*`, `0.0.0.0` or `[::]`.
    public var isEverywhere: Bool { ["*", "0.0.0.0", "[::]", "::"].contains(host) }
}
