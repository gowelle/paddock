import Darwin
import Foundation

/// Something listening on a TCP port Paddock needs.
public struct PortHolder: Codable, Equatable, Sendable {
    public let port: Int
    /// Nil when the holder is not visible to this user (e.g. a root process); only a failed bind showed it.
    public let pid: Int32?
    public let command: String?
    public let ownedByCurrentUser: Bool

    public init(port: Int, pid: Int32?, command: String?, ownedByCurrentUser: Bool) {
        self.port = port
        self.pid = pid
        self.command = command
        self.ownedByCurrentUser = ownedByCurrentUser
    }
}

public enum PortCheck {
    /// Listeners on each port, found with `lsof`; if `lsof` shows none, a failed bind of
    /// 127.0.0.1:<port> reports an unknown holder.
    public static func holders(of ports: [Int]) -> [PortHolder] {
        ports.flatMap { port -> [PortHolder] in
            let listed = lsofListeners(port: port)
            if !listed.isEmpty { return listed }
            return canBind(port: port)
                ? [] : [PortHolder(port: port, pid: nil, command: nil, ownedByCurrentUser: false)]
        }
    }

    /// One holder per listening process, from `lsof -F pcu` output.
    static func lsofListeners(port: Int) -> [PortHolder] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcu"]
        let output = Pipe()
        lsof.standardOutput = output
        lsof.standardError = FileHandle.nullDevice
        do { try lsof.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self), port: port, currentUID: getuid())
    }

    static func parse(_ text: String, port: Int, currentUID: uid_t) -> [PortHolder] {
        var holders: [PortHolder] = []
        var pid: Int32?
        var command: String?
        var uid: uid_t?
        func flush() {
            if let pid, !holders.contains(where: { $0.pid == pid }) {
                holders.append(PortHolder(port: port, pid: pid, command: command,
                                          ownedByCurrentUser: uid == currentUID))
            }
        }
        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                flush()
                pid = Int32(value); command = nil; uid = nil
            case "c": command = value
            case "u": uid = uid_t(value)
            default: break
            }
        }
        flush()
        return holders
    }

    /// Whether 127.0.0.1:<port> can be bound and listened on right now. SO_REUSEADDR so that
    /// lingering TIME_WAIT connections from a server we just stopped don't count as a holder.
    static func canBind(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return bound && listen(fd, 1) == 0
    }
}
