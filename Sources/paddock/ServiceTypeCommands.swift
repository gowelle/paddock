import ArgumentParser
import Foundation
import PaddockCore

/// `paddock service …`: databases, cache, search, mail and other services Paddock runs. (Not to be confused
/// with `ServiceCommands.swift`, which starts and stops Paddock itself.)
struct ServiceGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Add and run services such as mail, databases and caches.",
        subcommands: [
            ServiceList.self, ServiceAdd.self, ServiceStart.self, ServiceStop.self, ServiceRestart.self,
            ServiceRemove.self, ServiceUpdate.self, ServiceEnv.self, ServiceLogs.self, ServiceOpen.self,
            ServiceAvailable.self, ServiceCreateDatabase.self,
        ],
        defaultSubcommand: ServiceList.self
    )
}

extension CLI {
    /// The services Paddock can add.
    static func catalog() throws -> [CatalogEntry] {
        switch try sendRaw(.serviceCatalog, timeout: 30) {
        case .catalog(let entries): return entries
        case .error(_, let message): throw failure(message)
        case .ok, .removed, .databaseCreated, .envLines: throw unexpectedAnswer()
        }
    }

    /// The added service `typed` names (its id or name, any case).
    static func service(named typed: String, in status: EngineStatus) throws -> ServiceStatus {
        let wanted = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard let service = status.services.first(where: { $0.id == wanted })
                ?? status.services.first(where: { $0.name.lowercased() == wanted }) else {
            throw failure(Messages.serviceError(.unknownService(typed)))
        }
        return service
    }

    /// A development build on the real system says so before reading anything for a change it can't send.
    static func refuseChangesFromDevelopmentBuild() throws {
        if client.readOnly { throw failure(Messages.developmentBuild) }
    }

    /// Runs `work` (stopping Paddock); if it takes more than three seconds, says what it is waiting for:
    /// services may need up to a minute to stop cleanly (PostgreSQL's final checkpoint).
    static func whileWaitingForServices<T>(_ work: () throws -> T) rethrows -> T {
        let notice = SlowNotice()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { notice.show("Waiting for services to stop…") }
        defer { notice.finish() }
        return try work()
    }

    /// `Mail is running on port 1025.`
    static func runningLine(_ service: ServiceStatus) -> String {
        service.mainPort.map { "\(service.name) is running on port \($0)." } ?? "\(service.name) is running."
    }
}

struct ServiceList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the services you added.")

    func run() throws {
        let services = try CLI.send(.status, timeout: 30).services
        print(services.isEmpty
              ? "No services yet. See what you can add with: paddock service available"
              : Messages.serviceTable(services))
    }
}

struct ServiceAvailable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "available",
                                                    abstract: "List the services Paddock can add.")

    func run() throws {
        print(Messages.catalogTable(try CLI.catalog()))
    }
}

struct ServiceAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Download, set up and start a service, and print its .env lines.")
    @Argument(help: "The kind of service, such as mail (see: paddock service available).") var kind: String
    @Argument(help: "A series such as 18, or an exact version (default: the newest).") var version: String?

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let catalog = try CLI.catalog()
        guard let entry = catalog.first(where: { $0.kind == kind.lowercased() }) else {
            throw CLI.failure(Messages.serviceError(.unknownKind(kind, available: catalog.map(\.kind))))
        }
        let before = Set(try CLI.send(.status, timeout: 30).services.map(\.id))
        // The daemon reports no progress while it downloads, so this line is the progress.
        print("\(entry.series(matching: version)?.needsDownload ?? true ? "Downloading" : "Starting") \(entry.displayName)…")
        fflush(stdout)
        let status = try CLI.send(.serviceAdd(kind: entry.kind, version: version), timeout: 3600)
        guard let added = status.services.first(where: { !before.contains($0.id) }) else {
            throw CLI.unexpectedAnswer()
        }
        if let notice = added.notice { print(notice) }
        print(CLI.runningLine(added))
        let envLines = Messages.addedEnvLines(added)
        if !envLines.isEmpty {
            print("")
            print(envLines.joined(separator: "\n"))
        }
    }
}

struct ServiceStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start a service.")
    @Argument(help: "The service's name, such as mail.") var name: String

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let status = try CLI.send(.serviceStart(name: name))
        print(CLI.runningLine(try CLI.service(named: name, in: status)))
    }
}

struct ServiceStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a service.")
    @Argument(help: "The service's name, such as mail.") var name: String

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let status = try CLI.send(.serviceStop(name: name))
        print("\(try CLI.service(named: name, in: status).name) stopped.")
    }
}

struct ServiceRestart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Restart a service.")
    @Argument(help: "The service's name, such as mail.") var name: String

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let status = try CLI.send(.serviceRestart(name: name))
        print(CLI.runningLine(try CLI.service(named: name, in: status)))
    }
}

struct ServiceRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Stop a service and remove it from Paddock. Keeps its data unless asked.")
    @Argument(help: "The service's name, such as mail.") var name: String
    @Flag(name: .customLong("delete-data"), help: "Also delete the service's data. This can't be undone.")
    var deleteData = false

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let service = try CLI.service(named: name, in: try CLI.send(.status, timeout: 30))
        switch try CLI.sendRaw(.serviceRemove(name: service.id, deleteData: deleteData)) {
        case .removed(let path, _):
            print(deleteData ? "Removed \(service.name) and deleted its data."
                             : "Removed \(service.name). Its data is still at \(path).")
        case .error(_, let message):
            throw CLI.failure(message)
        case .ok, .catalog, .databaseCreated, .envLines:
            throw CLI.unexpectedAnswer()
        }
    }
}

struct ServiceUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Download the newest version of a service's series and switch to it.")
    @Argument(help: "The service's name, such as mail.") var name: String

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let before = try CLI.service(named: name, in: try CLI.send(.status, timeout: 30))
        if let version = before.updateAvailable {
            print("Downloading \(before.displayName) \(version)…")
            fflush(stdout)
        }
        let after = try CLI.service(named: before.id, in: try CLI.send(.serviceUpdate(name: before.id), timeout: 3600))
        print(after.version == before.version ? "\(after.name) is up to date (\(after.version))."
                                              : "\(after.name) now runs \(after.version).")
    }
}

struct ServiceCreateDatabase: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-db", abstract: "Create a database in a running service, such as PostgreSQL.")
    @Argument(help: "The service's name, such as postgres-18.") var name: String
    @Argument(help: "The new database's name: letters, numbers and underscores.") var database: String

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        switch try CLI.sendRaw(.serviceCreateDatabase(name: name, database: database), timeout: 120) {
        case .databaseCreated(let database, let existed, let status):
            let service = try CLI.service(named: name, in: status)
            print(Messages.databaseCreated(database, in: service.name, alreadyExisted: existed))
        case .error(_, let message):
            throw CLI.failure(message)
        case .ok, .catalog, .removed, .envLines:
            throw CLI.unexpectedAnswer()
        }
    }
}

struct ServiceEnv: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "env",
                                                    abstract: "Print a service's .env lines for a Laravel app.")
    @Argument(help: "The service's name, such as mail.") var name: String

    func run() throws {
        // The lines hold the service's secrets, which a development build may not read from the real home.
        try CLI.refuseChangesFromDevelopmentBuild()
        let service = try CLI.service(named: name, in: try CLI.send(.status, timeout: 30))
        switch try CLI.sendRaw(.serviceEnv(id: service.id), timeout: 30) {
        case .envLines(let lines):
            print(lines.joined(separator: "\n"))
        case .error(_, let message):
            throw CLI.failure(message)
        case .ok, .catalog, .removed, .databaseCreated:
            throw CLI.unexpectedAnswer()
        }
    }
}

struct ServiceLogs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Show the end of a service's log.")
    @Argument(help: "The service's name, such as mail.") var name: String

    func run() throws {
        let service = try CLI.service(named: name, in: try CLI.send(.status, timeout: 30))
        let log = CLI.paths.serviceLog(service.id)
        print(log.path)
        let lines = Logs.lastLines(of: log)
        if !lines.isEmpty { print(lines.joined(separator: "\n")) }
    }
}

struct ServiceOpen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a service's page in the browser.")
    @Argument(help: "The service's name, such as mail.") var name: String

    func run() throws {
        let service = try CLI.service(named: name, in: try CLI.send(.status, timeout: 30))
        guard let url = service.openURL else { throw CLI.failure("\(service.name) has no page to open.") }
        // PADDOCK_OPEN_COMMAND lets tests avoid launching a real browser.
        let command = ProcessInfo.processInfo.environment["PADDOCK_OPEN_COMMAND"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/bin/open"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = [url]
        do {
            try process.run()
        } catch {
            throw CLI.failure("Couldn't open \(url): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLI.failure("Couldn't open \(url).") }
    }
}

/// A line printed only while the work it describes is still going (never after it finished).
final class SlowNotice: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func show(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        print(line)
        fflush(stdout)
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
