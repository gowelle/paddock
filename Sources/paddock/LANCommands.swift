import ArgumentParser
import Foundation
import PaddockCore

/// `paddock lan …`: sharing chosen sites with other devices on the same network.
struct LANGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lan",
        abstract: "Share chosen sites with other devices on your network.",
        subcommands: [LANOn.self, LANOff.self, LANShare.self, LANUnshare.self])
}

struct LANOn: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on", abstract: "Share the chosen sites with other devices on your network.")

    func run() throws {
        let status = try CLI.send(.lan(enabled: true))
        guard let lan = status.lan else { throw CLI.unexpectedAnswer() }
        print(Messages.lanSummary(lan))
    }
}

struct LANOff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off", abstract: "Stop sharing sites with other devices on your network.")

    func run() throws {
        try CLI.send(.lan(enabled: false))
        print("Sites are no longer shared on your network.")
    }
}

struct LANShare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share", abstract: "Share a site with other devices on your network.")
    @Argument(help: "The site (default: the site containing the current directory).") var site: String?

    func run() throws {
        let target = try CLI.site(named: site, in: try CLI.send(.status, timeout: 30))
        let status = try CLI.send(.lanSite(site: target.name, enabled: true))
        guard let lan = status.lan else { throw CLI.unexpectedAnswer() }
        print(Messages.lanShared(LAN.host(for: target.name), lan: lan))
    }
}

struct LANUnshare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unshare", abstract: "Stop sharing a site with other devices on your network.")
    @Argument(help: "The site (default: the site containing the current directory).") var site: String?

    func run() throws {
        let target = try CLI.site(named: site, in: try CLI.send(.status, timeout: 30))
        try CLI.send(.lanSite(site: target.name, enabled: false))
        print(Messages.lanUnshared(LAN.host(for: target.name)))
    }
}
