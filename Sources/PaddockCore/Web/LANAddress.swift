import Darwin
import Foundation

/// The IPv4 address on which other devices on the network reach this Mac.
public enum LANAddress {
    public struct Candidate: Equatable, Sendable {
        public var name: String
        public var address: String
        public var isDown: Bool
        public var isLoopback: Bool
        public var isLinkLocal: Bool

        public init(name: String, address: String, isDown: Bool = false,
                    isLoopback: Bool = false, isLinkLocal: Bool = false) {
            self.name = name
            self.address = address
            self.isDown = isDown
            self.isLoopback = isLoopback
            self.isLinkLocal = isLinkLocal
        }
    }

    /// The best usable interface now, or nil when this Mac has no network address (Wi-Fi off, say).
    public static func primaryIPv4() -> String? {
        choose(from: candidates())
    }

    /// A private address on Wi-Fi (en*) beats one elsewhere, which beats a public address.
    static func choose(from candidates: [Candidate]) -> String? {
        candidates.filter { !$0.isDown && !$0.isLoopback && !$0.isLinkLocal }
            .sorted { rank($0) < rank($1) }
            .first?.address
    }

    private static func rank(_ candidate: Candidate) -> (Int, Int, String) {
        (isPrivate(candidate.address) ? 0 : 1, candidate.name.hasPrefix("en") ? 0 : 1, candidate.name)
    }

    static func isPrivate(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    private static func candidates() -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var found: [Candidate] = []
        for interface in sequence(first: head, next: { $0.pointee.ifa_next }) {
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                inet_ntop(AF_INET, &pointer.pointee.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            }
            guard converted != nil else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            let ip = String(cString: text)
            found.append(Candidate(
                name: String(cString: interface.pointee.ifa_name),
                address: ip,
                isDown: flags & IFF_UP == 0,
                isLoopback: flags & IFF_LOOPBACK != 0,
                isLinkLocal: ip.hasPrefix("169.254.")))
        }
        return found
    }
}
