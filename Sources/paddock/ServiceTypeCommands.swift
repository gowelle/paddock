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
            ServiceRemove.self, ServiceEnv.self, ServiceLogs.self, ServiceOpen.self, ServiceAvailable.self,
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
        case .ok, .removed: throw unexpectedAnswer()
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
    @Argument(help: "A version (default: the newest).") var version: String?

    func run() throws {
        try CLI.refuseChangesFromDevelopmentBuild()
        let catalog = try CLI.catalog()
        guard let entry = catalog.first(where: { $0.kind == kind.lowercased() }) else {
            throw CLI.failure(Messages.serviceError(.unknownKind(kind, available: catalog.map(\.kind))))
        }
        let before = Set(try CLI.send(.status, timeout: 30).services.map(\.id))
        // The daemon reports no progress while it downloads, so this line is the progress.
        print("Downloading \(entry.displayName)…")
        fflush(stdout)
        let status = try CLI.send(.serviceAdd(kind: entry.kind, version: version), timeout: 3600)
        guard let added = status.services.first(where: { !before.contains($0.id) }) else {
            throw CLI.unexpectedAnswer()
        }
        if let notice = added.notice { print(notice) }
        print(CLI.runningLine(added))
        if !added.env.isEmpty {
            print("")
            print(added.env.joined(separator: "\n"))
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
        case .ok, .catalog:
            throw CLI.unexpectedAnswer()
        }
    }
}

struct ServiceEnv: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "env",
                                                    abstract: "Print a service's .env lines for a Laravel app.")
    @Argument(help: "The service's name, such as mail.") var name: String

    func run() throws {
        let service = try CLI.service(named: name, in: try CLI.send(.status, timeout: 30))
        print(service.env.joined(separator: "\n"))
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
