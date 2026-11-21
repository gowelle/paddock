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
    /// For a holder `lsof` can't see: the `Server` header it answered an HTTP request with, e.g. `nginx/1.30.6`.
    public let serverHeader: String?
    /// For a holder `lsof` can't see: the well-known system server it is, e.g. `MacPorts nginx`.
    public let serviceName: String?
    /// The command that stops `serviceName`, for the owner to run; Paddock never runs it.
    public let stopCommand: String?

    public init(port: Int, pid: Int32?, command: String?, ownedByCurrentUser: Bool,
                executablePath: String? = nil, serverHeader: String? = nil, serviceName: String? = nil,
                stopCommand: String? = nil) {
        self.port = port
        self.pid = pid
        self.command = command
        self.ownedByCurrentUser = ownedByCurrentUser
        self.executablePath = executablePath
        let app = executablePath.flatMap(Self.enclosingApp(ofExecutable:))
        appBundlePath = app?.path
        appName = app?.name
        self.serverHeader = serverHeader
        self.serviceName = serviceName
        self.stopCommand = stopCommand
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

/// A web server macOS runs as a system launchd job (as root, so `lsof` can't see it), and how to stop it.
public struct KnownServer: Equatable, Sendable {
    public enum Kind: Sendable { case nginx, apache }
    /// The launchd label, e.g. `org.macports.nginx`.
    public let label: String
    /// The name the owner knows it by, e.g. `MacPorts nginx`.
    public let name: String
    /// The program the job usually runs (a reference only: never reported as the holder's program).
    public let binary: String
    public let stopCommand: String
    public let kind: Kind
}

public enum PortCheck {
    /// How long a test connection may take before the port counts as free.
    static let connectTimeout: TimeInterval = 0.2
    /// How long asking a hidden holder for its `Server` header may take in all.
    public static let probeTimeout: TimeInterval = 1

    /// Who serves each port. A port is held iff a TCP connection to 127.0.0.1 or [::1] on it is
    /// accepted (a normal user cannot test-bind ports below 1024, so binding would prove nothing);
    /// `lsof` then names the listening processes where it can see them. Where it can't (a root process),
    /// the holder is named as far as a normal user can: by the `Server` header it answers a `HEAD`
    /// request with (`serverHeader`) and by which well-known system launchd job is loaded (`runner`,
    /// read-only `launchctl print`).
    public static func holders(of ports: [Int], runner: CommandRunner = SystemCommandRunner(),
                               serverHeader: @escaping (Int) -> String? = { httpServerHeader(port: $0) })
        -> [PortHolder] {
        holders(of: ports, accepts: accepts(port:), listeners: lsofListeners(port:),
                hidden: { hiddenHolder(port: $0, serverHeader: serverHeader, runner: runner) })
    }

    static func holders(of ports: [Int], accepts: (Int) -> Bool, listeners: (Int) -> [PortHolder],
                        hidden: (Int) -> PortHolder = {
                            PortHolder(port: $0, pid: nil, command: nil, ownedByCurrentUser: false)
                        }) -> [PortHolder] {
        ports.flatMap { port -> [PortHolder] in
            guard accepts(port) else { return [] }
            let listed = listeners(port)
            return listed.isEmpty ? [hidden(port)] : listed
        }
    }

    // MARK: - Holders lsof can't see

    /// System launchd jobs that serve the web ports. Herd's helper is not here: it stays loaded after
    /// Herd quits, so it says nothing about who holds a port (a visible Herd process does).
    public static let knownServers: [KnownServer] = [
        KnownServer(label: "org.macports.nginx", name: "MacPorts nginx", binary: "/opt/local/sbin/nginx",
                    stopCommand: "sudo port unload nginx", kind: .nginx),
        KnownServer(label: "org.macports.apache2", name: "MacPorts Apache", binary: "/opt/local/sbin/httpd",
                    stopCommand: "sudo port unload apache2", kind: .apache),
        KnownServer(label: "org.apache.httpd", name: "the built-in Apache", binary: "/usr/sbin/httpd",
                    stopCommand: "sudo apachectl stop", kind: .apache),
        KnownServer(label: "homebrew.mxcl.nginx", name: "Homebrew nginx", binary: "/usr/local/opt/nginx/bin/nginx",
                    stopCommand: "sudo brew services stop nginx", kind: .nginx),
        KnownServer(label: "homebrew.mxcl.httpd", name: "Homebrew Apache", binary: "/usr/local/opt/httpd/bin/httpd",
                    stopCommand: "sudo brew services stop httpd", kind: .apache),
    ]

    /// A port's holder that `lsof` can't see, named by its `Server` header and the loaded system job.
    static func hiddenHolder(port: Int, serverHeader: (Int) -> String?, runner: CommandRunner) -> PortHolder {
        let header = serverHeader(port)
        let server = knownServer(header: header) { label in
            (try? runner.run("/bin/launchctl", ["print", "system/\(label)"]))?.status == 0
        }
        return PortHolder(port: port, pid: nil, command: nil, ownedByCurrentUser: false,
                          serverHeader: header, serviceName: server?.name,
                          stopCommand: server?.stopCommand)
    }

    /// The first known server whose job is loaded and that the header (if any) agrees with.
    static func knownServer(header: String?, isLoaded: (String) -> Bool) -> KnownServer? {
        knownServers.first { isConsistent($0, header: header) && isLoaded($0.label) }
    }

    /// No header proves nothing either way; a header must be the server's kind.
    static func isConsistent(_ server: KnownServer, header: String?) -> Bool {
        guard let header else { return true }
        return serverKind(header: header) == server.kind
    }

    /// `nginx/1.30.6` -> nginx; `Apache/2.4.62 (Unix)` or `httpd` -> Apache; anything else -> nil.
    static func serverKind(header: String) -> KnownServer.Kind? {
        let lower = header.lowercased()
        if lower.hasPrefix("nginx") { return .nginx }
        if lower.hasPrefix("apache") || lower.hasPrefix("httpd") { return .apache }
        return nil
    }

    /// The `Server` header 127.0.0.1:<port> (else [::1]) answers `HEAD / HTTP/1.0` with, within
    /// `timeout` seconds in all; nil if none. Plain HTTP only: on a TLS port nginx and Apache still
    /// answer a plain request with an error that carries the header.
    public static func httpServerHeader(port: Int, timeout: TimeInterval = probeTimeout) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        func remaining() -> Int32 { Int32(max(0, deadline.timeIntervalSinceNow) * 1000) }
        guard let fd = openConnection(port: port, ipv6: false, timeout: remaining())
                ?? openConnection(port: port, ipv6: true, timeout: remaining()) else { return nil }
        defer { close(fd) }
        var request = Array("HEAD / HTTP/1.0\r\nHost: localhost\r\nUser-Agent: Paddock\r\n\r\n".utf8)
        while !request.isEmpty {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, remaining()) == 1 else { return nil }
            let n = write(fd, request, request.count)
            guard n > 0 else { return nil }
            request.removeFirst(n)
        }
        var response: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 16384 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, remaining()) == 1 else { break }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            response += buffer[0..<n]
            if response.count >= 4, String(decoding: response, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        return serverHeader(inResponse: String(decoding: response, as: UTF8.self))
    }

    /// The `Server` header of an HTTP response's head, made `Messages.printable` (one line of printable
    /// ASCII, at most 64 characters); nil if it is not an HTTP response or has no usable header.
    static func serverHeader(inResponse text: String) -> String? {
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("HTTP/") == true else { return nil }
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "server" else { continue }
            // A bare LF or other control text inside the value goes no further than this.
            return Messages.printable(String(line[line.index(after: colon)...]))
        }
        return nil
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
        guard let fd = openConnection(port: port, ipv6: ipv6, timeout: Int32(connectTimeout * 1000)) else {
            return false
        }
        close(fd)
        return true
    }

    /// A non-blocking socket connected to the loopback address on `port` within `timeout` milliseconds;
    /// the caller closes it.
    static func openConnection(port: Int, ipv6: Bool, timeout: Int32) -> Int32? {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var connected = false
        defer { if !connected { close(fd) } }
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
        if rc != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeout) == 1 else { return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        }
        connected = true
        return fd
    }
}
