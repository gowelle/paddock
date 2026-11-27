import Foundation

/// What Paddock exposes to other devices on the same network: a separate listener, under its own names,
/// carrying only the sites the owner picked. Nothing else (services, Mailpit, databases) is reachable there.
public enum LAN {
    /// The suffix Paddock advertises over mDNS: `blog.paddock.local`.
    public static let domain = "paddock.local"
    /// The port tried first; another in `fallbackPorts` is used when it is taken.
    public static let defaultPort = 8080
    public static let fallbackPorts = 8080...8099
    /// Ports a normal user may bind, so a saved choice is one the LAN listener can use.
    public static func isUsablePort(_ port: Int) -> Bool { (1024...65535).contains(port) }

    public static func host(for site: String) -> String { "\(site).\(domain)" }
    public static func url(for site: String, port: Int) -> String { "http://\(host(for: site)):\(port)" }
}

/// The LAN listener as `status` reports it. Nil from a daemon that predates LAN exposure.
public struct LanStatus: Codable, Equatable, Sendable {
    /// The owner's master switch. Per-site choices mean nothing while it is off.
    public var enabled: Bool
    /// Whether the LAN listener has the port and forwards to Caddy now.
    public var running: Bool
    /// The port the listener holds (or would hold when started).
    public var port: Int
    /// This Mac's LAN address, for reaching the sites when mDNS names don't resolve; nil until known.
    public var address: String?

    public init(enabled: Bool, running: Bool, port: Int, address: String? = nil) {
        self.enabled = enabled
        self.running = running
        self.port = port
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case enabled, running, port, address }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? nil ?? LAN.defaultPort
        address = try c.decodeIfPresent(String.self, forKey: .address)
    }
}
