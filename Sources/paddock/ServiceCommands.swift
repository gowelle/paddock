import ArgumentParser
import Darwin
import Foundation
import PaddockCore

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start Paddock.")

    func run() throws {
        if !CLI.client.daemonIsRunning {
            try DaemonLauncher.launch(paths: CLI.paths)
        }
        switch try CLI.sendRaw(.start) {
        case .ok:
            print("Paddock is running.")
        case .error(let code, let message):
            if code == ErrorCode.portsBlocked,
               case .ok(let status)? = try? CLI.client.send(.status, timeout: 30), !status.blockedBy.isEmpty {
                throw CLI.failure(Messages.portsBlocked(status.blockedBy))
            }
            throw CLI.failure(message)
        }
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop Paddock.")

    func run() throws {
        guard CLI.client.daemonIsRunning else {
            print("Paddock isn't running.")
            return
        }
        try CLI.send(.shutdown, timeout: 60)
        // The daemon exits right after replying; give it a moment so `status` agrees.
        let deadline = Date().addingTimeInterval(5)
        while CLI.client.daemonIsRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        print("Paddock stopped.")
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart Paddock.")

    func run() throws {
        switch try CLI.sendRaw(.restart) {
        case .ok:
            print("Paddock restarted.")
        case .error(let code, let message):
            if code == ErrorCode.portsBlocked,
               case .ok(let status)? = try? CLI.client.send(.status, timeout: 30), !status.blockedBy.isEmpty {
                throw CLI.failure(Messages.portsBlocked(status.blockedBy))
            }
            throw CLI.failure(message)
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether Paddock is running, and its sites.")

    func run() throws {
        let response: Response
        do {
            response = try CLI.client.send(.status, timeout: 30)
        } catch ClientError.daemonNotRunning {
            print(Messages.daemonNotRunning) // A query, not a failure.
            return
        } catch {
            throw CLI.failure("Paddock gave an unexpected answer: \(error)")
        }
        guard case .ok(let status) = response else {
            if case .error(_, let message) = response { throw CLI.failure(message) }
            return
        }
        if status.running {
            print("Paddock is running.")
        } else if !status.blockedBy.isEmpty {
            print(Messages.portsBlocked(status.blockedBy))
        } else {
            print("Paddock is stopped.")
        }
        print("Default PHP: \(status.defaultPHP.map(\.description) ?? "none installed")")
        print("")
        print(status.sites.isEmpty
              ? "No sites yet. Park a folder with: paddock park"
              : Messages.siteTable(status.sites))
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the end of each Paddock log.")
    private static let lineCount = 50
    private static let tailBytes = 256 * 1024

    func run() throws {
        let dir = CLI.paths.log
        print(dir.path)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".log") }.sorted()
        for name in files {
            print("\n==> \(name) <==")
            let lines = Self.lastLines(of: dir.appendingPathComponent(name))
            if !lines.isEmpty { print(lines.joined(separator: "\n")) }
        }
    }

    private static func lastLines(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return Array(text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).dropLast(text.hasSuffix("\n") ? 1 : 0).suffix(lineCount))
    }
}

/// Starts `paddockd` so it outlives this process. Task 13 replaces this with the LaunchAgent.
enum DaemonLauncher {
    static func launch(paths: Paths) throws {
        guard let binary = daemonBinary() else {
            throw CLI.failure("Can't find paddockd next to paddock.")
        }
        try? paths.ensureDirectories()
        let logPath = paths.log.appendingPathComponent("paddockd.log").path

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own session, so closing the terminal or exiting the CLI doesn't take the daemon down.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings([binary.path]) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, binary.path, &actions, &attributes, argv, envp)
            }
        }
        guard rc == 0 else {
            throw CLI.failure("Couldn't start Paddock: \(String(cString: strerror(rc))).")
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if CLI.client.daemonIsRunning { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CLI.failure("Paddock didn't start within 10 seconds. See \(logPath)")
    }

    private static func daemonBinary() -> URL? {
        var directories: [URL] = []
        if let argv0 = CommandLine.arguments.first, argv0.contains("/") {
            directories.append(URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let executable = Bundle.main.executableURL {
            directories.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        return directories.map { $0.appendingPathComponent("paddockd") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}
