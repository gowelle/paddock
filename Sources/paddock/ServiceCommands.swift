import ArgumentParser
import Foundation
import PaddockCore

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start Paddock.")

    func run() throws {
        // Through the LaunchAgent on the owner's system, or detached for a development home.
        do {
            _ = try CLI.launcher.ensureRunning()
        } catch let error as DaemonLaunchError {
            throw CLI.failure(error.message(retry: "Run paddock start"))
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
        let outcome: DaemonLauncher.StopOutcome
        do { outcome = try CLI.launcher.stop() } catch DaemonLaunchError.failed(let message) {
            throw CLI.failure(message)
        } catch {
            throw CLI.failure("Couldn't stop Paddock: \(error)")
        }
        print(outcome == .stopped ? "Paddock stopped." : "Paddock isn't running.")
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove Paddock's resolver, login item and certificate trust. Keeps your sites and data.")

    private static let stillInstalled = "Paddock is still installed. Run paddock uninstall to try again."

    func run() throws {
        do {
            for line in try CLI.lifecycle.uninstall() { print(line) }
        } catch ResolverError.cancelled {
            throw CLI.failure(Self.stillInstalled)
        } catch let error as ResolverError {
            CLI.printError("Couldn't restore the resolver: \(error)")
            throw CLI.failure(Self.stillInstalled)
        } catch {
            throw CLI.failure("Couldn't uninstall Paddock: \(error)")
        }
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
            throw CLI.failure(Messages.unexpectedAnswer(error))
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
