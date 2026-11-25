import ArgumentParser
import Foundation
import PaddockCore

struct Paddock: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paddock",
        abstract: "Serve every folder in a parked directory at <folder>.test.",
        subcommands: [
            Park.self, Forget.self, Parked.self,
            Link.self, Unlink.self, Links.self,
            Secure.self, Unsecure.self, Trust.self,
            Isolate.self, Unisolate.self, Use.self, XdebugGroup.self,
            Start.self, Stop.self, Restart.self, Status.self, DoctorCommand.self, Uninstall.self,
            Open.self, Logs.self,
            ServiceGroup.self, TaskGroup.self, DatabaseGroup.self, MCP.self,
        ]
    )
}

/// What every command shares: talking to the daemon, printing, and finding the current site.
enum CLI {
    static var paths: Paths { .current }
    static var client: PaddockClient { PaddockClient(paths: paths) }
    /// The system pieces `start`, `stop` and `uninstall` touch; the real system unless a test replaces it.
    nonisolated(unsafe) static var services = SystemServices.production(settings: .current)
    static var lifecycle: SystemLifecycle {
        SystemLifecycle(services: services, paths: paths, settings: Settings.current)
    }
    static var launcher: DaemonLauncher { DaemonLauncher(lifecycle: lifecycle, paths: paths) }

    /// Stops a command that would change the owner's system or installed Paddock (restart, trust) when this
    /// program may not: `SystemLifecycle.checkMayChangeSystem` decides.
    static func checkMayChangeSystem() throws {
        do { try lifecycle.checkMayChangeSystem() } catch let error as DaemonLaunchError {
            throw failure(error.message())
        }
    }
    static var tld: String { Settings.current.tld }
    static var currentDirectory: String { FileManager.default.currentDirectoryPath }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Prints `message` to stderr and returns the error that makes the process exit with 1.
    static func failure(_ message: String) -> ExitCode {
        printError(message)
        return .failure
    }

    /// Sends a request; connection problems are reported and thrown, daemon answers are returned as is.
    static func sendRaw(_ request: Request, timeout: TimeInterval = 600) throws -> Response {
        do {
            return try client.send(request, timeout: timeout)
        } catch ClientError.daemonNotRunning {
            throw failure(Messages.daemonNotRunning)
        } catch ClientError.timedOut {
            throw failure(Messages.didNotAnswer)
        } catch ClientError.developmentBuild {
            throw failure(Messages.developmentBuild)
        } catch {
            throw failure(Messages.unexpectedAnswer(error))
        }
    }

    /// Sends a request and returns the status; a daemon error is printed to stderr and thrown.
    @discardableResult
    static func send(_ request: Request, timeout: TimeInterval = 600) throws -> EngineStatus {
        switch try sendRaw(request, timeout: timeout) {
        case .ok(let status), .removed(_, let status), .databaseCreated(_, _, let status): return status
        case .error(_, let message): throw failure(message)
        case .catalog, .envLines: throw unexpectedAnswer()
        }
    }

    /// For an answer that doesn't fit the request (a catalog where a status was expected).
    static func unexpectedAnswer() -> ExitCode {
        failure(Messages.unexpectedAnswer(ClientError.badResponse("an answer for another request")))
    }

    /// The absolute form of a path typed on the command line, relative to the current directory.
    static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
            .standardizedFileURL.path
    }

    /// The site the user means: the named one, or the one containing the current directory.
    static func site(named typed: String?, in status: EngineStatus) throws -> Site {
        if let typed {
            let name = Messages.siteName(typed, tld: tld)
            guard let site = status.sites.first(where: { $0.name == name }) else {
                throw failure("Paddock doesn't serve a site named \(name).")
            }
            return site
        }
        return try siteContainingCurrentDirectory(in: status)
    }

    /// With `quietly`, a folder that is no site's throws without printing (for a command with a fallback).
    static func siteContainingCurrentDirectory(in status: EngineStatus, quietly: Bool = false) throws -> Site {
        let registry = SiteRegistry(
            state: StateStore(paths: paths).load(),
            defaultPHP: status.defaultPHP ?? PHPVersion(major: 8, minor: 5))
        guard let site = registry.site(containing: currentDirectory),
              let served = status.sites.first(where: { $0.name == site.name }) else {
            if quietly { throw ExitCode.failure }
            throw failure(Messages.notASite)
        }
        return served
    }

    static func version(_ text: String) throws -> PHPVersion {
        guard let version = PHPVersion(text) else { throw failure(Messages.minimumPHP) }
        return version
    }
}
