import ArgumentParser
import Foundation
import PaddockCore

struct Park: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve every folder in a directory at <folder>.test.")
    @Argument(help: "The directory to park (default: the current directory).") var path: String?

    func run() throws {
        let dir = CLI.absolute(path ?? CLI.currentDirectory)
        try CLI.send(.park(path: dir))
        print("Parked \(dir); each folder in it is now served at <folder>.\(CLI.tld).")
    }
}

struct Forget: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop serving a parked directory.")
    @Argument(help: "The directory to forget (default: the current directory).") var path: String?

    func run() throws {
        let dir = CLI.absolute(path ?? CLI.currentDirectory)
        try CLI.send(.forget(path: dir))
        print("Forgot \(dir).")
    }
}

struct Parked: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the parked directories.")

    func run() throws {
        try CLI.send(.status, timeout: 30)
        let parked = StateStore(paths: CLI.paths).load().parked
        print(parked.isEmpty ? "No directories are parked. Park one with: paddock park" : parked.joined(separator: "\n"))
    }
}

struct Link: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve the current directory at <name>.test.")
    @Argument(help: "The site name (default: the current folder's name).") var name: String?

    func run() throws {
        let dir = CLI.currentDirectory
        let chosen = name ?? URL(fileURLWithPath: dir).lastPathComponent
        // `foo.test` means the site `foo`, as for unlink and secure.
        guard let site = Messages.normalizedSiteName(chosen, tld: CLI.tld) else {
            throw CLI.failure("\"\(chosen)\" can't be turned into a site name; use letters or digits.")
        }
        try CLI.send(.link(name: site, path: dir))
        print("\(site).\(CLI.tld) now serves \(dir).")
    }
}

struct Unlink: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop serving a linked site.")
    @Argument(help: "The site name (default: the current folder's name).") var name: String?

    func run() throws {
        let chosen = name ?? URL(fileURLWithPath: CLI.currentDirectory).lastPathComponent
        let site = Messages.siteName(chosen, tld: CLI.tld)
        try CLI.send(.unlink(name: site))
        print("\(site).\(CLI.tld) is no longer linked.")
    }
}

struct Links: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the linked sites.")

    func run() throws {
        try CLI.send(.status, timeout: 30)
        let links = StateStore(paths: CLI.paths).load().links
        if links.isEmpty {
            print("No sites are linked. Link one with: paddock link")
        } else {
            print(links.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: "\n"))
        }
    }
}

struct Secure: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve a site over HTTPS.")
    @Argument(help: "The site (default: the site containing the current directory).") var site: String?

    func run() throws {
        // Securing also makes macOS trust Paddock's certificate.
        try CLI.checkMayChangeSystem()
        let target = try CLI.site(named: site, in: try CLI.send(.status, timeout: 30))
        switch try CLI.sendRaw(.secure(site: target.name)) {
        case .ok(let status):
            print(status.trustEnabled ? "\(target.host) is now served over HTTPS."
                  : Messages.securedWithoutTrust(host: target.host))
        case .error(_, let message):
            // For needs_trust the daemon says why: not trusted yet, or the certificate isn't ready.
            throw CLI.failure(message)
        case .catalog, .removed, .databaseCreated:
            throw CLI.unexpectedAnswer()
        }
    }
}

struct Unsecure: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve a site over plain HTTP.")
    @Argument(help: "The site (default: the site containing the current directory).") var site: String?

    func run() throws {
        let target = try CLI.site(named: site, in: try CLI.send(.status, timeout: 30))
        try CLI.send(.unsecure(site: target.name))
        print("\(target.host) is now served over HTTP.")
    }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open a site in the browser.")
    @Argument(help: "The site (default: the site containing the current directory).") var site: String?

    func run() throws {
        let target = try CLI.site(named: site, in: try CLI.send(.status, timeout: 30))
        // PADDOCK_OPEN_COMMAND lets tests avoid launching a real browser.
        let command = ProcessInfo.processInfo.environment["PADDOCK_OPEN_COMMAND"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/bin/open"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = [target.url]
        do {
            try process.run()
        } catch {
            throw CLI.failure("Couldn't open \(target.url): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLI.failure("Couldn't open \(target.url).") }
    }
}

struct Trust: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Make macOS trust Paddock's certificate for HTTPS sites.")

    func run() throws {
        try CLI.checkMayChangeSystem()
        switch try CLI.sendRaw(.trust) {
        case .ok:
            print(Messages.trusted)
        case .error(_, let message):
            throw CLI.failure(message)
        case .catalog, .removed, .databaseCreated:
            throw CLI.unexpectedAnswer()
        }
    }
}
