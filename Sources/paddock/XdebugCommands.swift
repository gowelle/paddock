import ArgumentParser
import Foundation
import PaddockCore

struct XdebugGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xdebug",
        abstract: "Switch Xdebug on or off for a PHP version.",
        discussion: """
            Xdebug is switched per PHP version: every site on that version, and `php` in the terminal, follow it. \
            While on, a debugging session starts only when a request asks for one (the browser extension, or \
            XDEBUG_TRIGGER=1); your editor listens on port 9003.
            """,
        subcommands: [XdebugOn.self, XdebugOff.self, XdebugStatus.self],
        defaultSubcommand: XdebugStatus.self)

    /// The version named, else the one the current folder's site uses, else the default.
    static func version(_ text: String?, status: EngineStatus) throws -> PHPVersion {
        if let text { return try CLI.version(text) }
        if let site = try? CLI.siteContainingCurrentDirectory(in: status, quietly: true) { return site.php }
        guard let version = status.defaultPHP ?? status.installedPHP.max() else {
            throw CLI.failure(MultiCall.noPHPMessage)
        }
        return version
    }

    static func set(_ text: String?, enabled: Bool) throws {
        let version = try version(text, status: try CLI.send(.status, timeout: 30))
        try CLI.send(.xdebug(version: version, enabled: enabled))
        print(enabled ? Messages.xdebugTurnedOn(version) : Messages.xdebugTurnedOff(version))
    }
}

struct XdebugOn: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on", abstract: "Switch Xdebug on for a PHP version (default: the current site's).")
    @Argument(help: "A PHP version such as 8.4.") var version: String?

    func run() throws { try XdebugGroup.set(version, enabled: true) }
}

struct XdebugOff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off", abstract: "Switch Xdebug off for a PHP version (default: the current site's).")
    @Argument(help: "A PHP version such as 8.4.") var version: String?

    func run() throws { try XdebugGroup.set(version, enabled: false) }
}

struct XdebugStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show which PHP versions have Xdebug on.")

    func run() throws {
        let status = try CLI.send(.status, timeout: 30)
        print(Messages.xdebugStatus(installed: status.installedPHP, on: status.xdebug, available: status.xdebugAvailable))
    }
}
