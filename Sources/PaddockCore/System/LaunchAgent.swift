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

    static let launchctl = "/bin/launchctl"

    public init(runner: CommandRunner, plist: URL = LaunchAgent.defaultPlist, paths: Paths = .current) {
        self.runner = runner
        self.plist = plist
        self.paths = paths
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
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// True iff the plist on disk is what `install(daemon:)` would write.
    public func isCurrent(daemon: URL) -> Bool {
        (try? String(contentsOf: plist, encoding: .utf8)) == plistContents(daemon: daemon)
    }

    /// Writes the plist and loads it, replacing a loaded copy. launchd then runs the daemon at once.
    public func install(daemon: URL) throws {
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.log, withIntermediateDirectories: true)
        try Data(plistContents(daemon: daemon).utf8).write(to: plist, options: .atomic)
        if isLoaded() { try launchctl(["bootout", service]) }
        try launchctl(["bootstrap", domain, plist.path])
    }

    /// Unloads the agent; launchd sends the daemon SIGTERM and it shuts down cleanly. Keeps the plist.
    /// Returns whether it was loaded.
    @discardableResult
    public func stop() throws -> Bool {
        guard isLoaded() else { return false }
        try launchctl(["bootout", service])
        return true
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
