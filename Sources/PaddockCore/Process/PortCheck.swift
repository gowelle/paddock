import Darwin
import Foundation

/// Something listening on a TCP port Paddock needs.
public struct PortHolder: Codable, Equatable, Sendable {
    public let port: Int
    /// Nil when the holder is not visible to this user (e.g. a root process); only a failed bind showed it.
    public let pid: Int32?
    public let command: String?
    public let ownedByCurrentUser: Bool
    /// The holder's program, e.g. `/Applications/Herd.app/Contents/Resources/nginx-x86`.
    public let executablePath: String?
    /// The application the program belongs to, e.g. `/Applications/Herd.app`, if it is inside one.
    public let appBundlePath: String?
    /// That application's name, e.g. `Herd`.
    public let appName: String?

    public init(port: Int, pid: Int32?, command: String?, ownedByCurrentUser: Bool,
                executablePath: String? = nil) {
        self.port = port
        self.pid = pid
        self.command = command
        self.ownedByCurrentUser = ownedByCurrentUser
        self.executablePath = executablePath
        let app = executablePath.flatMap(Self.enclosingApp(ofExecutable:))
        appBundlePath = app?.path
        appName = app?.name
    }

    /// The outermost `*.app` folder on `path`, and its name without `.app`:
    /// `/Applications/Herd.app/Contents/Resources/nginx` -> (`/Applications/Herd.app`, `Herd`).
    public static func enclosingApp(ofExecutable path: String) -> (path: String, name: String)? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        // The last component is the program itself, which is not an application folder.
        guard let index = components.dropLast().firstIndex(where: {
            $0.count > 4 && $0.lowercased().hasSuffix(".app")
        }) else { return nil }
        let bundle = NSString.path(withComponents: Array(components[...index]))
        return (bundle, String(components[index].dropLast(4)))
    }
}

/// Why the HTTP/HTTPS ports could not be bound.
public enum PortBindProblem: Equatable, Sendable {
    /// Something else is listening on the port.
    case inUse
    /// macOS doesn't let this user listen on the port (ports below 1024 on a specific address).
    case notPermitted
}

/// What stops Paddock from listening on its ports.
public struct PortReport: Equatable, Sendable {
    public var holders: [PortHolder]
    /// Ports nobody holds but this user may not listen on.
    public var notPermitted: [Int]

    public var isClear: Bool { holders.isEmpty && notPermitted.isEmpty }
}

public enum PortCheck {
    /// Listeners on each port, found with `lsof`; if `lsof` shows none, a failed bind of
    /// 127.0.0.1 and ::1 reports either an unknown holder or a port this user may not use.
    public static func report(ports: [Int]) -> PortReport {
        report(ports: ports, listeners: lsofListeners(port:), bindProblem: bindError(port:))
    }

    static func report(ports: [Int], listeners: (Int) -> [PortHolder],
                       bindProblem: (Int) -> PortBindProblem?) -> PortReport {
        var result = PortReport(holders: [], notPermitted: [])
        for port in ports {
            let listed = listeners(port)
            if !listed.isEmpty {
                result.holders += listed
                continue
            }
            switch bindProblem(port) {
            case .inUse?:
                result.holders.append(PortHolder(port: port, pid: nil, command: nil, ownedByCurrentUser: false))
            case .notPermitted?:
                result.notPermitted.append(port)
            case nil:
                break
            }
        }
        return result
    }

    /// Only the holders; a port that is merely not permitted has none.
    public static func holders(of ports: [Int]) -> [PortHolder] {
        report(ports: ports).holders
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
        return parse(String(decoding: data, as: UTF8.self), port: port, currentUID: getuid(),
                     executablePath: executablePath(pid:))
    }

    static func parse(_ text: String, port: Int, currentUID: uid_t,
                      executablePath: (Int32) -> String? = { _ in nil }) -> [PortHolder] {
        var holders: [PortHolder] = []
        var pid: Int32?
        var command: String?
        var uid: uid_t?
        func flush() {
            if let pid, !holders.contains(where: { $0.pid == pid }) {
                holders.append(PortHolder(port: port, pid: pid, command: command,
                                          ownedByCurrentUser: uid == currentUID,
                                          executablePath: executablePath(pid)))
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

    /// The full path of a process's program, if macOS reports it.
    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Why 127.0.0.1:<port> or [::1]:<port> (both of which Caddy binds) can't be listened on, if either can't.
    static func bindError(port: Int) -> PortBindProblem? {
        classify([bindErrno(port: port, ipv6: false), bindErrno(port: port, ipv6: true)])
    }

    /// Reads bind results (0 for success, else errno) for the loopback addresses. "Address in use"
    /// anywhere means a holder; "permission denied" means this user may not listen there; a missing
    /// IPv6 loopback is no problem. Any other failure counts as a holder, as before.
    static func classify(_ results: [Int32]) -> PortBindProblem? {
        let failures = results.filter { $0 != 0 && $0 != EADDRNOTAVAIL && $0 != EAFNOSUPPORT && $0 != EPROTONOSUPPORT }
        if failures.contains(EADDRINUSE) { return .inUse }
        if failures.isEmpty { return nil }
        if failures.allSatisfy({ $0 == EACCES || $0 == EPERM }) { return .notPermitted }
        return .inUse
    }

    /// Binds (and, with `listen`, listens on) the loopback address on `port`, then closes the socket.
    /// Returns 0 on success, else the errno. SO_REUSEADDR so that lingering TIME_WAIT connections from
    /// a server we just stopped don't count as a holder.
    static func bindErrno(port: Int, ipv6: Bool, listen shouldListen: Bool = true) -> Int32 {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let rc: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            addr.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard rc == 0 else { return errno }
        guard shouldListen else { return 0 }
        return Darwin.listen(fd, 1) == 0 ? 0 : errno
    }
}
