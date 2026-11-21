import CryptoKit
import Foundation

/// The root-owned launchd entry that gives Paddock ports 80 and 443 on the real system: launchd opens
/// 127.0.0.1 and ::1 on both ports and, on the first connection, runs `paddock-ports` as the owner's
/// normal user with those sockets; it copies each connection to Caddy's Unix sockets. Installing and
/// removing it happens inside the single privileged script (see `Resolver.install(preceding:)` and
/// `Resolver.restore(then:)`); nothing of Paddock runs as root afterwards.
public struct PortHelper: Sendable {
    public static let label = "app.paddock.ports"
    public static let defaultInstalledBinary = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/app.paddock.ports")
    public static let defaultPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/app.paddock.ports.plist")
    /// Printed (with exit 0, nothing changed) by the install fragment when something else answers on a port.
    public static let busyMarker = "PADDOCK_PORTS_BUSY"
    static let service = "system/\(label)"

    /// The programs the privileged script runs. The script assigns them literally at its top and never
    /// reads them from the environment; only tests build a script with stand-ins. All are compiled
    /// programs (no interpreter that honours environment variables).
    struct Tools: Sendable {
        var launchctl = "/bin/launchctl"
        var chown = "/usr/sbin/chown"
        var nc = "/usr/bin/nc"
        var sha256 = "/sbin/sha256"
        var mktemp = "/usr/bin/mktemp"
        var base64 = "/usr/bin/base64"
        /// How many 0.1 s waits the script gives launchd to let go of a booted-out job.
        var unloadPolls = 50
    }

    /// The bundled helper this build installs.
    public let source: URL
    let user: String
    let paths: Paths
    let runner: CommandRunner
    public let installedBinary: URL
    public let plist: URL
    let tools: Tools

    public init(source: URL, user: String, paths: Paths, runner: CommandRunner,
                installedBinary: URL = PortHelper.defaultInstalledBinary, plist: URL = PortHelper.defaultPlist) {
        self.init(source: source, user: user, paths: paths, runner: runner,
                  installedBinary: installedBinary, plist: plist, tools: Tools())
    }

    init(source: URL, user: String, paths: Paths, runner: CommandRunner,
         installedBinary: URL, plist: URL, tools: Tools) {
        self.source = source
        self.user = user
        self.paths = paths
        self.runner = runner
        self.installedBinary = installedBinary
        self.plist = plist
        self.tools = tools
    }

    /// The LaunchDaemon: loopback-only TCP stream sockets on 80 and 443, the helper run as `user` on
    /// demand (no `RunAtLoad`, no `KeepAlive`: launchd starts it on the first connection).
    public func plistData() throws -> Data {
        func sockets(_ port: String) -> [[String: Any]] {
            [("127.0.0.1", "IPv4"), ("::1", "IPv6")].map { node, family in
                ["SockNodeName": node, "SockServiceName": port, "SockFamily": family,
                 "SockType": "stream", "SockProtocol": "TCP", "SockPassive": true]
            }
        }
        let dictionary: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [installedBinary.path, "launchd", paths.httpSocket.path, paths.httpsSocket.path],
            "UserName": user,
            "Sockets": ["http": sockets("80"), "https": sockets("443")],
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    /// True iff the installed helper is this build's (same SHA-256) and the installed plist is exactly
    /// `plistData()`. Only reads files; needs no privileges.
    public func filesCurrent() -> Bool {
        guard let installed = Self.sha256(of: installedBinary), installed == Self.sha256(of: source),
              let data = try? Data(contentsOf: plist), let wanted = try? plistData() else { return false }
        return data == wanted
    }

    /// Whether launchd has the job loaded (`launchctl print`, read-only).
    public func isLoaded() -> Bool {
        (try? runner.run("/bin/launchctl", ["print", Self.service]))?.status == 0
    }

    /// Set up and working as far as launchd goes: this build's files, and the job loaded. Anything less
    /// (an outdated file, the job booted out or switched off as a background item) needs the setup prompt.
    public func isInstalled() -> Bool {
        filesCurrent() && isLoaded()
    }

    /// What `paddock status` reports: installed, and a TCP connection to 127.0.0.1 on `port` is accepted
    /// (launchd holds the socket and answers it).
    public func isServing(port: Int, accepts: (Int) -> Bool = PortCheck.acceptsIPv4(port:)) -> Bool {
        isInstalled() && accepts(port)
    }

    /// Whether any part of an installation is there: either file, or the loaded job.
    public func isPresent() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: installedBinary.path) || fm.fileExists(atPath: plist.path) || isLoaded()
    }

    /// Whether Paddock's own launchd job holds the ports (any version of it): its plist is in place and
    /// launchd has the job. The user-level port check then doesn't count it as a blocker.
    public func ownsPorts() -> Bool {
        FileManager.default.fileExists(atPath: plist.path) && isLoaded()
    }

    // MARK: - Privileged script fragments

    /// One line of shell for the privileged script. It:
    /// 1. prints `busyMarker` and exits 0, changing nothing, if anything accepts a TCP connection on
    ///    127.0.0.1 or ::1 port 80 or 443 while Paddock's own job is not loaded;
    /// 2. creates the helper directory (root:wheel 755) if missing;
    /// 3. writes the helper (embedded base64) to a root `mktemp` file beside its destination, verifies its
    ///    SHA-256 against the embedded hash, `chmod 755`, `chown root:wheel`; writes the plist the same way
    ///    (`chmod 644`);
    /// 4. boots out any loaded job and waits (bounded) until launchd has let go of it;
    /// 5. moves both files into place and bootstraps the job (tried once more after a second).
    /// Any failure in 2–5 removes what this run created, reports `PrivilegedStage.portsInstall` on stderr
    /// and exits non-zero, so a resolver step after it never runs. An interrupted run removes its temp
    /// files (`Resolver.trapLine`).
    public func installScriptFragment() throws -> String {
        let binary = try Data(contentsOf: source)
        let hash = Self.hex(SHA256.hash(data: binary))
        let plistBytes = try plistData()
        let q = Resolver.shellQuote
        let cleanUp = "/bin/rm -f ${HT:+\"$HT\"} ${PT:+\"$PT\"}; HT=; PT=; "
            + "[ -n \"$MADE_HDIR\" ] && /bin/rmdir \"$HDIR\" 2>/dev/null"
        let removeInstalled = "\"$LAUNCHCTL\" bootout \"$JOB\" >/dev/null 2>&1; /bin/rm -f \"$HB\" \"$PL\""
        let fail = { (detail: String) in "\(PrivilegedStage.portsInstall.report(detail)); \(cleanUp); exit 1" }
        let statements = header + [
            "HDIR=\(q(installedBinary.deletingLastPathComponent().path))",
            "PDIR=\(q(plist.deletingLastPathComponent().path))",
            "MADE_HDIR=",
            // 1. Something else holds a port: say so and change nothing.
            "if ! \"$LAUNCHCTL\" print \"$JOB\" >/dev/null 2>&1; then for P in 80 443; do for A in 127.0.0.1 ::1; do "
                + "if \"$NC\" -z -G 1 \"$A\" \"$P\" >/dev/null 2>&1; then echo \(Self.busyMarker); exit 0; fi; "
                + "done; done; fi",
            // 2. The helper directory.
            "if [ ! -d \"$HDIR\" ]; then MADE_HDIR=1; if ! { /bin/mkdir -p \"$HDIR\" && /bin/chmod 755 \"$HDIR\" "
                + "&& \"$CHOWN\" root:wheel \"$HDIR\"; }; then \(fail("could not create " + installedBinary.deletingLastPathComponent().path)); fi; fi",
            // 3. Both files, staged beside their destinations.
            "HT=$(\"$MKTEMP\" \"$HDIR/.paddock.XXXXXX\") || { \(fail("could not create a temporary file")); }",
            "if ! { printf %s \(q(binary.base64EncodedString())) | \"$BASE64\" -D > \"$HT\" "
                + "&& S=$(\"$SHA256\" -q \"$HT\") && [ \"$S\" = \(q(hash)) ] "
                + "&& /bin/chmod 755 \"$HT\" && \"$CHOWN\" root:wheel \"$HT\"; }; then "
                + "\(fail("paddock-ports did not match its checksum")); fi",
            "PT=$(\"$MKTEMP\" \"$PDIR/.paddock.XXXXXX\") || { \(fail("could not create a temporary file")); }",
            "if ! { printf %s \(q(plistBytes.base64EncodedString())) | \"$BASE64\" -D > \"$PT\" "
                + "&& /bin/chmod 644 \"$PT\" && \"$CHOWN\" root:wheel \"$PT\"; }; then "
                + "\(fail("could not write the launchd entry")); fi",
            // 4. Any running job goes first (not loaded is fine), bounded wait until launchd has let go.
            "\"$LAUNCHCTL\" bootout \"$JOB\" >/dev/null 2>&1",
            "N=0; while \"$LAUNCHCTL\" print \"$JOB\" >/dev/null 2>&1; do N=$((N+1)); "
                + "if [ \"$N\" -ge \(tools.unloadPolls) ]; then \(fail(Self.label + " is still loaded")); fi; "
                + "/bin/sleep 0.1; done",
            // 5. Into place, then load. A bootstrap right after a bootout can fail once while launchd tears down.
            "if ! { /bin/mv -f \"$HT\" \"$HB\" && /bin/mv -f \"$PT\" \"$PL\"; }; then "
                + "\(removeInstalled); \(fail("could not move the files into place")); fi",
            "HT=; PT=",
            "if ! \"$LAUNCHCTL\" bootstrap system \"$PL\"; then /bin/sleep 1; "
                + "if ! \"$LAUNCHCTL\" bootstrap system \"$PL\"; then \(removeInstalled); "
                + "\(fail("launchd did not load " + Self.label)); fi; fi",
        ]
        return statements.joined(separator: "; ")
    }

    /// One line of shell for the privileged script, run after the resolver steps: boots the job out
    /// ("not loaded" is fine), waits (bounded) until launchd has let go, then removes the plist and the
    /// installed helper. Failures report `PrivilegedStage.portsRemoval`.
    public func uninstallScriptFragment() -> String {
        let fail = { (detail: String) in "\(PrivilegedStage.portsRemoval.report(detail)); exit 1" }
        let statements = header + [
            "\"$LAUNCHCTL\" bootout \"$JOB\" >/dev/null 2>&1",
            "N=0; while \"$LAUNCHCTL\" print \"$JOB\" >/dev/null 2>&1; do N=$((N+1)); "
                + "if [ \"$N\" -ge \(tools.unloadPolls) ]; then \(fail(Self.label + " is still loaded")); fi; "
                + "/bin/sleep 0.1; done",
            "/bin/rm -f \"$PL\" \"$HB\" || { \(fail("could not remove its files")); }",
        ]
        return statements.joined(separator: "; ")
    }

    /// The interrupt trap, then literal assignments of every program and path the fragments use.
    private var header: [String] {
        let q = Resolver.shellQuote
        return [
            Resolver.trapLine,
            "LAUNCHCTL=\(q(tools.launchctl))", "CHOWN=\(q(tools.chown))", "NC=\(q(tools.nc))",
            "SHA256=\(q(tools.sha256))", "MKTEMP=\(q(tools.mktemp))", "BASE64=\(q(tools.base64))",
            "JOB=\(q(Self.service))", "HB=\(q(installedBinary.path))", "PL=\(q(plist.path))",
        ]
    }

    // MARK: - Hashing

    static func sha256(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A yes/no answer that is slow to work out (a process launch, a connection attempt), kept for `ttl`
/// seconds. Reading never waits: a stale answer is returned while a fresh one is worked out in the
/// background. The first answer is worked out when the check is made, unless an `initial` answer is
/// given: that one stands until the first read starts working out the real one.
public final class CachedCheck: @unchecked Sendable {
    private let lock = NSLock()
    private let ttl: TimeInterval
    private let compute: @Sendable () -> Bool
    private var answer: Bool
    private var computedAt: Date
    private var refreshing = false

    public init(ttl: TimeInterval = 3, initial: Bool? = nil, compute: @escaping @Sendable () -> Bool) {
        self.ttl = ttl
        self.compute = compute
        if let initial {
            answer = initial
            computedAt = .distantPast
        } else {
            answer = compute()
            computedAt = Date()
        }
    }

    /// Works out a fresh answer now, for callers that may wait.
    public func refresh() {
        let fresh = compute()
        lock.lock()
        answer = fresh
        computedAt = Date()
        lock.unlock()
    }

    public var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(computedAt) >= ttl && !refreshing {
            refreshing = true
            DispatchQueue.global().async { [self] in
                let fresh = compute()
                lock.lock()
                answer = fresh
                computedAt = Date()
                refreshing = false
                lock.unlock()
            }
        }
        return answer
    }
}
