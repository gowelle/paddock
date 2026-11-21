import Darwin
import Foundation

/// The environment the user's terminal has, so a task finds `bun`, `node` and the rest as it would there:
/// captured from the user's login, interactive shell. Its values may be secrets: they are never logged, only
/// how many there were.
public struct ShellEnvironment: Sendable, CustomStringConvertible {
    public let variables: [String: String]
    /// True when the shell couldn't be read and `variables` is the basic fallback.
    public let usedFallback: Bool
    /// The shell tasks run under (`[shell, "-c", run]`).
    public let shell: String

    public init(variables: [String: String], usedFallback: Bool, shell: String) {
        self.variables = variables
        self.usedFallback = usedFallback
        self.shell = shell
    }

    /// For the daemon log: how many variables, and whether the fallback was used. Never a value.
    public var description: String {
        usedFallback ? "the shell's environment couldn't be read; tasks use the basic fallback (\(variables.count) variables)"
                     : "captured \(variables.count) variables from \(shell)"
    }

    /// Runs `shell` with `arguments` and `environment` in `directory`, stdin from /dev/null, its whole process
    /// group killed at `timeout`; returns what it printed, or nil if it didn't run or was cut off.
    public typealias Runner = @Sendable (_ shell: String, _ arguments: [String], _ environment: [String: String],
                                         _ directory: URL, _ timeout: TimeInterval) -> String?

    public static let timeout: TimeInterval = 5

    /// Shell bookkeeping and what Paddock sets itself: never passed on to tasks.
    static func isDropped(_ name: String) -> Bool {
        name.hasPrefix("PADDOCK_") || ["OLDPWD", "PWD", "SHLVL", "_"].contains(name)
    }

    /// Runs `shell -l -i -c '<print a marker line>; exec env -0'` from the home folder, with `environment` less
    /// Paddock's own variables. Everything a startup file prints before the marker is ignored; a shell that
    /// fails, prints no marker or takes longer than `timeout` (a startup file waiting for something) gives
    /// the fallback.
    public static func capture(shell: String, environment: [String: String], timeout: TimeInterval = timeout,
                               runner: Runner = live) -> ShellEnvironment {
        let marker = "PADDOCK-ENV-" + UUID().uuidString
        let command = "exec 2>/dev/null; printf '\\n%s\\n' '\(marker)'; exec /usr/bin/env -0"
        let base = environment.filter { !$0.key.hasPrefix("PADDOCK_") }
        let home = URL(fileURLWithPath: base["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory(),
                       isDirectory: true)
        if let output = runner(shell, ["-l", "-i", "-c", command], base, home, timeout),
           let parsed = parse(output, marker: marker) {
            return ShellEnvironment(variables: parsed.filter { !isDropped($0.key) }, usedFallback: false, shell: shell)
        }
        return ShellEnvironment(variables: fallback(environment: environment), usedFallback: true, shell: shell)
    }

    /// The entries after the marker line: NUL-separated `NAME=value` pairs (values may hold newlines and `=`).
    /// What follows the last NUL is not an entry. Nil without the marker or without a single entry.
    static func parse(_ output: String, marker: String) -> [String: String]? {
        guard let start = output.range(of: "\n" + marker + "\n") else { return nil }
        var entries = output[start.upperBound...].components(separatedBy: "\0")
        entries.removeLast() // After the last NUL: empty, or noise.
        var variables: [String: String] = [:]
        for entry in entries {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            variables[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return variables.isEmpty ? nil : variables
    }

    /// A basic environment for when the shell can't be read.
    public static func fallback(environment: [String: String]) -> [String: String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let user = environment["USER"] ?? NSUserName()
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:\(home)/.bun/bin",
            "HOME": home, "USER": user, "LOGNAME": environment["LOGNAME"] ?? user,
            "SHELL": userShell(environment: environment), "TMPDIR": environment["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
        ]
    }

    /// `SHELL` when it is an absolute path to a program, else the account's login shell, else /bin/zsh.
    public static func userShell(environment: [String: String]) -> String {
        func usable(_ path: String?) -> String? {
            guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        }
        if let shell = usable(environment["SHELL"]) { return shell }
        if let entry = getpwuid(getuid()), let shell = usable(String(cString: entry.pointee.pw_shell)) { return shell }
        return "/bin/zsh"
    }

    /// What a task runs with: these variables, Paddock's `bin` first on PATH (so `php` and `composer` are the
    /// site's), and, for any home but the owner's real one, `PADDOCK_HOME`, so those commands use this home.
    public func forTasks(paths: Paths) -> [String: String] {
        var environment = variables.filter { !Self.isDropped($0.key) }
        let path = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        environment["PATH"] = paths.bin.path + (path.map { ":" + $0 } ?? "")
        if !paths.isSystemHome { environment["PADDOCK_HOME"] = paths.home.path }
        return environment
    }

    /// The real shell, run like a service step: its own process group, stdin from /dev/null, killed at the
    /// deadline. stdout only matters; the command sends its own stderr nowhere after the marker.
    public static let live: Runner = { shell, arguments, environment, directory, timeout in
        guard let outcome = try? ServiceStepRunner.run(executable: shell, arguments: arguments, environment: environment,
                                                       directory: directory, stdin: nil, timeout: timeout, killGrace: 0.5,
                                                       isCancelled: { false }),
              outcome.end == .exited(0) else { return nil }
        return outcome.output
    }
}
