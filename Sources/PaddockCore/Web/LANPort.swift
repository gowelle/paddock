import Darwin
import Foundation

/// Picks the port the LAN listener holds: a preferred one, then the next free in the fallback range.
public enum LANPort {
    /// PADDOCK_LAN_PORT when it names a usable port, else the saved choice, else the default.
    public static func preferred(saved: Int?,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        if let text = environment["PADDOCK_LAN_PORT"], let port = Int(text), LAN.isUsablePort(port) {
            return port
        }
        if let saved, LAN.isUsablePort(saved) { return saved }
        return LAN.defaultPort
    }

    /// The first port `isFree` accepts: the preferred one, then 8080–8099. Nil when all are taken.
    public static func choose(saved: Int?,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              isFree: (Int) -> Bool = isFree) -> Int? {
        let first = preferred(saved: saved, environment: environment)
        return ([first] + LAN.fallbackPorts.filter { $0 != first }).first(where: isFree)
    }

    /// Whether the LAN listener could bind every interface on `port` now.
    public static func isFree(_ port: Int) -> Bool {
        freeOn(family: AF_INET, port: port) && freeOn(family: AF_INET6, port: port)
    }

    private static func freeOn(family: Int32, port: Int) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Like the listener itself: a port left in TIME_WAIT by the last run is free to take again.
        // A live listener still refuses the second bind.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET6 {
            var only: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            address.sin6_addr = in6addr_any
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
