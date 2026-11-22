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
        subcommands: [XdebugOn.self, XdebugOff.self, XdebugStatus.self, XdebugZed.self],
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

struct XdebugZed: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zed",
        abstract: "Write Zed's debug configuration for the current site (never over an existing one).")

    func run() throws {
        let status = try CLI.send(.status, timeout: 30)
        // The site's folder when the current one is inside a site, else the current folder.
        let site = try? CLI.siteContainingCurrentDirectory(in: status, quietly: true)
        let root = URL(fileURLWithPath: site?.path ?? CLI.currentDirectory, isDirectory: true)
        let version = try XdebugGroup.version(nil, status: status)
        let entry = Xdebug.zedConfiguration(port: Xdebug.clientPort(ini: CLI.paths.phpIni(version)))
        let file = root.appendingPathComponent(".zed", isDirectory: true).appendingPathComponent("debug.json")
        let shown = Messages.displayName(file.path, limit: 512) ?? file.path
        if FileManager.default.fileExists(atPath: file.path) {
            print(Messages.zedConfigExists(shown, entry: entry), terminator: "")
        } else {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Fails rather than replaces if the file appeared meanwhile.
                try Data(entry.utf8).write(to: file, options: .withoutOverwriting)
            } catch {
                throw CLI.failure("Paddock couldn't write \(shown): \(error.localizedDescription)")
            }
            print(Messages.zedConfigWritten(shown))
        }
        if !status.xdebug.contains(version) {
            print("Xdebug is off for PHP \(version). Switch it on with: paddock xdebug on \(version)")
        }
    }
}
