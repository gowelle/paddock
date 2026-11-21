import Darwin
import Foundation

public enum LaunchAgentError: Error, Equatable {
    case failed(String)
}

/// Runs `paddockd` as a per-user LaunchAgent, so it starts at login and restarts after a crash.
public struct LaunchAgent: Sendable {
    public static let label = "app.paddock.paddockd"

    let runner: CommandRunner
    public let plist: URL
    let paths: Paths
    let waits: Waits

    static let launchctl = "/bin/launchctl"

    /// How long to wait for launchd. Tests shorten them.
    public struct Waits: Sendable {
        /// The longest `bootout` is given to finish unloading the job.
        public var unload: TimeInterval = 5
        public var poll: TimeInterval = 0.1
        /// The pause before trying a failed `bootstrap` once more.
        public var bootstrapRetry: TimeInterval = 1

        public init(unload: TimeInterval = 5, poll: TimeInterval = 0.1, bootstrapRetry: TimeInterval = 1) {
            self.unload = unload
            self.poll = poll
            self.bootstrapRetry = bootstrapRetry
        }
    }

    public init(runner: CommandRunner, plist: URL = LaunchAgent.defaultPlist, paths: Paths = .current,
                waits: Waits = Waits()) {
        self.runner = runner
        self.plist = plist
        self.paths = paths
        self.waits = waits
    }

    public static var defaultPlist: URL {
        defaultDirectory.appendingPathComponent("\(label).plist")
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var domain: String { "gui/\(getuid())" }
    private var service: String { "\(domain)/\(Self.label)" }

    /// No `EnvironmentVariables`: a launched daemon uses the real home and the default ports.
    /// `ExitTimeOut` gives a stopping daemon 20 seconds to stop its web stack before launchd kills it.
    public func plistContents(daemon: URL) -> String {
        let log = paths.log.appendingPathComponent("paddockd.log").path
        let dictionary: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [daemon.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "ProcessType": "Interactive",
            "ExitTimeOut": 20,
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// True iff the plist on disk is what `install(daemon:)` would write.
    public func isCurrent(daemon: URL) -> Bool {
        (try? String(contentsOf: plist, encoding: .utf8)) == plistContents(daemon: daemon)
    }

    /// The daemon a plist on disk runs, if that plist is exactly what `install(daemon:)` would write
    /// for it and the daemon is still there. Lets `paddock start` work without a `paddockd` of its own.
    public func installedDaemon() -> URL? {
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let program = (dictionary["ProgramArguments"] as? [String])?.first else { return nil }
        let daemon = URL(fileURLWithPath: program)
        guard isCurrent(daemon: daemon), FileManager.default.isExecutableFile(atPath: daemon.path) else { return nil }
        return daemon
    }

    /// Writes the plist (unless it already says exactly this) and loads it, replacing a loaded copy.
    /// launchd then runs the daemon at once. A bootstrap right after a bootout can fail while launchd is
    /// still tearing the old job down, so a failed bootstrap is tried once more after a short pause.
    public func install(daemon: URL) throws {
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.log, withIntermediateDirectories: true)
        if !isCurrent(daemon: daemon) {
            try Data(plistContents(daemon: daemon).utf8).write(to: plist, options: .atomic)
        }
        if isLoaded() { try unload() }
        do {
            try launchctl(["bootstrap", domain, plist.path])
        } catch {
            Thread.sleep(forTimeInterval: waits.bootstrapRetry)
            try launchctl(["bootstrap", domain, plist.path])
        }
    }

    /// Unloads the agent; launchd sends the daemon SIGTERM and it shuts down cleanly. Keeps the plist.
    /// Returns whether it was loaded.
    @discardableResult
    public func stop() throws -> Bool {
        guard isLoaded() else { return false }
        try unload()
        return true
    }

    /// Boots the job out and waits (bounded) until launchd no longer has it. `bootout` may exit non-zero
    /// while the daemon is still exiting, so success means "not loaded afterwards", whatever it returned.
    private func unload() throws {
        let result = try runner.run(Self.launchctl, ["bootout", service])
        let deadline = Date().addingTimeInterval(waits.unload)
        while isLoaded() {
            guard Date() < deadline else {
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LaunchAgentError.failed(output.isEmpty ? "\(Self.label) is still loaded." : output)
            }
            Thread.sleep(forTimeInterval: waits.poll)
        }
    }

    /// Unloads the agent and deletes its plist.
    public func uninstall() throws {
        try stop()
        try? FileManager.default.removeItem(at: plist)
    }

    /// Starts the loaded job's daemon again (launchd leaves it idle after a clean exit).
    public func kickstart() throws {
        try launchctl(["kickstart", service])
    }

    /// Stops the running daemon and starts it again (`kickstart -k`), for a daemon of another build.
    public func restart() throws {
        try launchctl(["kickstart", "-k", service])
    }

    public func isLoaded() -> Bool {
        (try? runner.run(Self.launchctl, ["print", service]))?.status == 0
    }

    private func launchctl(_ arguments: [String]) throws {
        let result = try runner.run(Self.launchctl, arguments)
        guard result.status == 0 else {
            throw LaunchAgentError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
