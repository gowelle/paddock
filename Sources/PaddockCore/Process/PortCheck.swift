import Darwin
import Foundation

/// Something listening on a TCP port Paddock needs.
public struct PortHolder: Codable, Equatable, Sendable {
    public let port: Int
    /// Nil when the holder is not visible to this user (e.g. a root process); only a connection showed it.
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

public enum PortCheck {
    /// How long a test connection may take before the port counts as free.
    static let connectTimeout: TimeInterval = 0.2

    /// Who serves each port. A port is held iff a TCP connection to 127.0.0.1 or [::1] on it is
    /// accepted (a normal user cannot test-bind ports below 1024, so binding would prove nothing);
    /// `lsof` then names the listening processes where it can see them, else the holder is unknown.
    public static func holders(of ports: [Int]) -> [PortHolder] {
        holders(of: ports, accepts: accepts(port:), listeners: lsofListeners(port:))
    }

    static func holders(of ports: [Int], accepts: (Int) -> Bool,
                        listeners: (Int) -> [PortHolder]) -> [PortHolder] {
        ports.flatMap { port -> [PortHolder] in
            guard accepts(port) else { return [] }
            let listed = listeners(port)
            return listed.isEmpty ? [PortHolder(port: port, pid: nil, command: nil, ownedByCurrentUser: false)] : listed
        }
    }

    /// Whether 127.0.0.1:<port> or [::1]:<port> accepts a TCP connection within `connectTimeout`.
    static func accepts(port: Int) -> Bool {
        connects(port: port, ipv6: false) || connects(port: port, ipv6: true)
    }

    /// Whether 127.0.0.1:<port> accepts a TCP connection within `connectTimeout`.
    public static func acceptsIPv4(port: Int) -> Bool {
        connects(port: port, ipv6: false)
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

    private static func connects(port: Int, ipv6: Bool) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let rc: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            addr.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
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
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(connectTimeout * 1000)) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
    }
}
