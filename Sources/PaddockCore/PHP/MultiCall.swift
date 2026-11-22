import Darwin
import Foundation

/// The `paddock` binary doubles as `php` and `composer` (symlinks in `bin/`). When it is run under
/// one of those names it picks the PHP for the current folder and replaces itself with it.
public enum MultiCall {
    public enum Plan: Equatable {
        case notMultiCall
        case noPHP
        /// `setEnvironment` holds only variables to add; the rest is inherited by `execv`.
        case exec(path: String, arguments: [String], setEnvironment: [String: String])
    }

    public static let noPHPMessage = "No PHP installed. Open Paddock or run: paddock use 8.5"

    public static func plan(argv0: String, arguments: [String], directory: String,
                            environment: [String: String], paths: Paths,
                            resources: () -> URL = { Bundled.resources }) -> Plan {
        let name = (argv0 as NSString).lastPathComponent
        guard name == "php" || name == "composer" else { return .notMultiCall }
        let resolver = PHPResolver(paths: paths)
        guard let version = resolver.version(forDirectory: directory) else { return .noPHP }
        let binary = paths.phpDir(version).appendingPathComponent("php").path

        var argv = [binary]
        if let ini = resolver.ini(for: version) { argv += ["-c", ini.path] }
        // Xdebug follows the version's switch for `php`. Composer is left without it: it would only be slower,
        // and it restarts itself without Xdebug anyway.
        if name == "php" { argv += resolver.xdebugArguments(for: version) }
        // COMPOSER_HOME is left to Composer (the owner's ~/.composer, or what they set), so their
        // auth.json, global config and global packages keep working.
        if name == "composer" {
            argv.append(resources().appendingPathComponent("composer.phar").path)
        }
        // While something listens for dumps, `php` in the terminal sends its own there too; a choice the
        // user's shell already made (VAR_DUMPER_FORMAT) is left alone.
        let dumps = environment[DumpDestination.formatVariable] == nil ? resolver.dumpEnvironment() : [:]
        return .exec(path: binary, arguments: argv + arguments, setEnvironment: dumps)
    }

    /// Returns normally only when this process was not started as `php` or `composer`.
    public static func runIfInvokedAsShim() {
        let args = CommandLine.arguments
        guard let argv0 = args.first else { return }
        let plan = plan(argv0: argv0, arguments: Array(args.dropFirst()),
                        directory: FileManager.default.currentDirectoryPath,
                        environment: ProcessInfo.processInfo.environment, paths: .current)
        switch plan {
        case .notMultiCall:
            return
        case .noPHP:
            FileHandle.standardError.write(Data((noPHPMessage + "\n").utf8))
            exit(1)
        case .exec(let path, let arguments, let set):
            for (key, value) in set { setenv(key, value, 1) }
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
            argv.append(nil)
            execv(path, argv)
            let reason = String(cString: strerror(errno))
            FileHandle.standardError.write(Data("Could not run \(path): \(reason)\n".utf8))
            exit(127)
        }
    }
}
