import ArgumentParser
import Foundation
import PaddockCore

/// Installs `version` first when it is missing. The daemon reports no progress while it downloads,
/// so a single "Installing…" line is the progress.
private func ensureInstalled(_ version: PHPVersion, status: EngineStatus) throws {
    guard !status.installedPHP.contains(version) else { return }
    print("Installing PHP \(version)…")
    fflush(stdout)
    switch try CLI.sendRaw(.installPHP(version: version)) {
    case .ok:
        print("PHP \(version) installed.")
    case .error(let code, let message):
        if code == ErrorCode.phpNotAvailable { throw CLI.failure(Messages.phpNotAvailable(version)) }
        throw CLI.failure(message)
    case .catalog, .removed, .databaseCreated, .envLines:
        throw CLI.unexpectedAnswer()
    }
}

struct Use: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Make a PHP version the default for every site.")
    @Argument(help: "A PHP version such as 8.4.") var version: String

    func run() throws {
        let php = try CLI.version(version)
        try ensureInstalled(php, status: try CLI.send(.status, timeout: 30))
        try CLI.send(.use(version: php))
        print("PHP \(php) is now the default.")
    }
}

struct Isolate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pin the current site to a PHP version.")
    @Argument(help: "A PHP version such as 8.4.") var version: String

    func run() throws {
        let php = try CLI.version(version)
        let status = try CLI.send(.status, timeout: 30)
        let site = try CLI.siteContainingCurrentDirectory(in: status)
        try ensureInstalled(php, status: status)
        try CLI.send(.isolate(site: site.name, version: php))
        print("\(site.host) now uses PHP \(php).")
    }
}

struct Unisolate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Return the current site to the default PHP version.")

    func run() throws {
        let site = try CLI.siteContainingCurrentDirectory(in: try CLI.send(.status, timeout: 30))
        let status = try CLI.send(.unisolate(site: site.name))
        let suffix = status.defaultPHP.map { " (PHP \($0))" } ?? ""
        print("\(site.host) now uses the default PHP\(suffix).")
    }
}
