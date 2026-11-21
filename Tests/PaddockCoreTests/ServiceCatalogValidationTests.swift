import XCTest
@testable import PaddockCore

/// Every catalog (bundled, injected, or later hosted) is checked as a whole when it is loaded; the first
/// problem rejects it with a precise message.
final class ServiceCatalogValidationTests: XCTestCase {
    private func valid(kind: String = "sample", version: String = "1.2", series: String = "1",
                       start: RecipeCommand = RecipeCommand(executable: "{bin}/sample",
                                                            arguments: ["--port", "{port.main}", "{data}"],
                                                            environment: ["SAMPLE_HOME": "{data}"]),
                       initialise: [RecipeCommand] = [RecipeCommand(executable: "{bin}/init", arguments: ["{data}"],
                                                                    stdin: "x")],
                       ports: [RecipePort] = [RecipePort(name: "main", preferred: 4000)],
                       socket: String? = "{run}/s.sock", stopSignal: String = "TERM",
                       assets: [RecipeAsset] = [RecipeAsset(artifact: Artifact(url: URL(string: "https://example.invalid/s.tar.gz")!,
                                                                               sha256: "00"), archive: "tar.gz")],
                       configFiles: [RecipeFile] = [RecipeFile(path: "{config}/s.conf", contents: "port {port.main}")],
                       env: [String] = ["SAMPLE_PORT={port.main}"], openURL: String? = nil) -> ServiceRecipe {
        ServiceRecipe(kind: kind, displayName: "Sample", version: version, series: series, licence: "MIT",
                      assets: assets, initialise: initialise, start: start, ready: .tcp(port: "{port.main}"),
                      stopSignal: stopSignal, ports: ports, socket: socket, env: env, openURL: openURL,
                      configFiles: configFiles)
    }

    private func assertRejected(_ recipes: [ServiceRecipe], _ fragment: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertThrowsError(try ServiceCatalog.validate(recipes), file: file, line: line) { error in
            guard case .invalid(let message)? = error as? ServiceCatalogError else {
                return XCTFail("\(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(fragment), "\(message) should mention \(fragment)", file: file, line: line)
        }
    }

    func testAValidCatalogAndTheBundledOnePass() throws {
        XCTAssertNoThrow(try ServiceCatalog.validate([valid()]))
        XCTAssertNoThrow(try ServiceCatalog.validate(try ServiceCatalog.bundled().recipes))
        XCTAssertNoThrow(try ServiceCatalog.validate([valid(start: RecipeCommand(executable: "{php}",
                                                                                   arguments: ["{resources}/x.php"]))]))
    }

    func testNames() {
        assertRejected([valid(kind: "Sample")], "kind")
        assertRejected([valid(kind: "bin")], "kind")
        assertRejected([valid(kind: "a..b")], "kind")
        assertRejected([valid(kind: "../x")], "kind")
        assertRejected([valid(kind: "s.q")], "kind")
        assertRejected([valid(series: "1/2")], "series")
        assertRejected([valid(series: "..")], "series")
        assertRejected([valid(version: "1 2")], "version")
        assertRejected([valid(version: "-1")], "version")
    }

    func testExecutablesRunFromTheRecipesBinariesOrPHP() {
        assertRejected([valid(start: RecipeCommand(executable: "/bin/sh", arguments: ["-c", "x"]))], "under {bin}/")
        assertRejected([valid(start: RecipeCommand(executable: "{bin}/../../bin/sh"))], "under {bin}/")
        assertRejected([valid(start: RecipeCommand(executable: "{data}/x"))], "under {bin}/")
        assertRejected([valid(initialise: [RecipeCommand(executable: "/usr/bin/env")])], "under {bin}/")
        assertRejected([valid(start: RecipeCommand(executable: "{php}x"))], "under {bin}/")
    }

    func testEnvironment() {
        func start(_ environment: [String: String]) -> RecipeCommand {
            RecipeCommand(executable: "{bin}/sample", environment: environment)
        }
        assertRejected([valid(start: start(["lower": "x"]))], "environment")
        assertRejected([valid(start: start(["DYLD_INSERT_LIBRARIES": "{data}/x"]))], "DYLD_")
        assertRejected([valid(start: start(["PATH": "/tmp/evil"]))], "PATH")
        assertRejected([valid(start: start(["HOME": "/Users/x"]))], "HOME")
        assertRejected([valid(start: start(["TMPDIR": "{data}/../.."]))], "TMPDIR")
        XCTAssertNoThrow(try ServiceCatalog.validate([valid(start: start(["HOME": "{data}", "TMPDIR": "{run}/tmp"]))]))
    }

    func testSocketAndConfigFilesStayInTheInstancesFolders() {
        assertRejected([valid(socket: "{data}/s.sock")], "socket")
        assertRejected([valid(socket: "{run}/")], "socket")
        assertRejected([valid(socket: "{run}")], "socket")
        assertRejected([valid(socket: "{run}/../x.sock")], "socket")
        assertRejected([valid(configFiles: [RecipeFile(path: "{data}/x.conf", contents: "")])], "config file")
        assertRejected([valid(configFiles: [RecipeFile(path: "{config}/../x", contents: "")])], "config file")
        assertRejected([valid(configFiles: [RecipeFile(path: "{config}/", contents: "")])], "config file")
    }

    func testEveryPlaceholderIsKnown() {
        assertRejected([valid(env: ["X={nope}"])], "{nope}")
        assertRejected([valid(env: ["X={port.other}"])], "{port.other}")
        assertRejected([valid(openURL: "http://127.0.0.1:{port.http}")], "{port.http}")
        assertRejected([valid(configFiles: [RecipeFile(path: "{config}/a", contents: "{dat}")])], "{dat}")
        assertRejected([valid(start: RecipeCommand(executable: "{bin}/s", arguments: [.ifSocket(["{sockt}"])]))], "{sockt}")
    }

    func testStdinOnlyOnStepsAndKnownSignals() {
        assertRejected([valid(start: RecipeCommand(executable: "{bin}/s", stdin: "x"))], "stdin")
        assertRejected([valid(stopSignal: "KILL")], "stop signal")
    }

    func testAssets() {
        let url = URL(string: "https://example.invalid/s.tar.gz")!
        assertRejected([valid(assets: [RecipeAsset(artifact: Artifact(url: url, sha256: "00"), archive: "rar")])], "archive")
        assertRejected([valid(assets: [RecipeAsset(artifact: Artifact(url: url, sha256: "00"), archive: "binary")])],
                       "installAs")
        assertRejected([valid(assets: [RecipeAsset(artifact: Artifact(url: url, sha256: "00"), archive: "binary",
                                                   installAs: "../x")])], "installAs")
        assertRejected([valid(assets: [RecipeAsset(artifact: Artifact(url: URL(string: "https://example.invalid/")!,
                                                                      sha256: "00"), archive: "tar.gz")])], "file name")
    }

    func testPorts() {
        assertRejected([valid(ports: [RecipePort(name: "main", preferred: 4000), RecipePort(name: "main", preferred: 4001)])],
                       "port")
        assertRejected([valid(ports: [RecipePort(name: "main", preferred: 80)])], "1024")
        assertRejected([valid(ports: [RecipePort(name: "main", preferred: 70000)])], "65535")
    }

    func testOneRecipePerKindSeriesAndVersion() {
        assertRejected([valid(), valid()], "more than once")
        XCTAssertNoThrow(try ServiceCatalog.validate([valid(), valid(version: "1.3")]))
    }

    /// Path-bearing fields take one leading folder placeholder and literal text after it: `{name}` (free
    /// text) can never steer a program, socket, config file or path variable elsewhere.
    func testPathFieldsTakeOnlyALeadingFolder() {
        func start(_ executable: String = "{bin}/sample", _ environment: [String: String] = [:]) -> RecipeCommand {
            RecipeCommand(executable: executable, environment: environment)
        }
        assertRejected([valid(start: start("{bin}/{name}"))], "under {bin}/")
        assertRejected([valid(start: start("{bin}/x/{id}"))], "under {bin}/")
        assertRejected([valid(start: start("{bin}//x"))], "under {bin}/")
        assertRejected([valid(socket: "{run}/{name}.sock")], "socket")
        assertRejected([valid(configFiles: [RecipeFile(path: "{config}/{id}.conf", contents: "")])], "config file")
        assertRejected([valid(start: start("{bin}/sample", ["HOME": "{data}/{name}"]))], "HOME")
        assertRejected([valid(start: start("{bin}/sample", ["PATH": "{data}/x:/anything"]))], "PATH")
        assertRejected([valid(start: start("{bin}/sample", ["PATH": "{data}/x:"]))], "PATH")
        assertRejected([valid(start: start("{bin}/sample", ["TMPDIR": "{run}{name}"]))], "TMPDIR")
        XCTAssertNoThrow(try ServiceCatalog.validate([valid(start: start("{bin}/sample", ["PATH": "{bin}:{config}/bin",
                                                                                          "TMPDIR": "{run}"]))]))
    }

    func testDisplayNamesAreShortPrintableAndHaveNoSlash() {
        func named(_ name: String) -> ServiceRecipe {
            ServiceRecipe(kind: "sample", displayName: name, version: "1.0", licence: "MIT", assets: [],
                          start: RecipeCommand(executable: "{bin}/s"), ready: .tcp(port: "{port.main}"),
                          ports: [RecipePort(name: "main", preferred: 4000)])
        }
        for bad in ["../../../../bin/sh", "", " ", "a\nb", "tab\there", String(repeating: "x", count: 65), "a\u{1B}[31m"] {
            assertRejected([named(bad)], "display name")
        }
        XCTAssertNoThrow(try ServiceCatalog.validate([named("Redis (Valkey)")]))
    }

    func testEnvironmentDenylist() {
        func env(_ name: String, _ value: String = "x") -> ServiceRecipe {
            valid(start: RecipeCommand(executable: "{bin}/sample", environment: [name: value]))
        }
        for name in ["LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "PERL5LIB", "PERL5OPT", "PYTHONPATH",
                     "PYTHONSTARTUP", "RUBYOPT", "NODE_OPTIONS", "BASH_ENV", "ENV", "IFS", "CDPATH", "GLOBIGNORE"] {
            assertRejected([env(name, "{data}/x")], name)
        }
        assertRejected([env("PHPRC", "/etc/php.ini")], "PHPRC")
        assertRejected([env("PHP_INI_SCAN_DIR", "/etc/php.d")], "PHP_INI_SCAN_DIR")
        XCTAssertNoThrow(try ServiceCatalog.validate([env("PHPRC", "{config}/php.ini")]))
        XCTAssertNoThrow(try ServiceCatalog.validate([env("PHP_INI_SCAN_DIR", "{config}/conf.d")]))
    }

    func testStripComponentsAndOneInstallPerKindAndVersion() {
        let url = URL(string: "https://example.invalid/s.tar.gz")!
        assertRejected([valid(assets: [RecipeAsset(artifact: Artifact(url: url, sha256: "00"), archive: "tar.gz",
                                                   stripComponents: 9)])], "stripComponents")
        assertRejected([valid(assets: [RecipeAsset(artifact: Artifact(url: url, sha256: "00"), archive: "tar.gz",
                                                   stripComponents: -1)])], "stripComponents")
        assertRejected([valid(series: "1"), valid(series: "1.2")], "more than once")
    }

    // MARK: - What PostgreSQL needs

    /// The socket is `{run}/` and one file name; that name may carry the instance's port (`.s.PGSQL.5432`),
    /// which renders to digits, and nothing else.
    func testTheSocketFileNameMayCarryAPortAndNothingElse() {
        XCTAssertNoThrow(try ServiceCatalog.validate([valid(socket: "{run}/.s.PGSQL.{port.main}")]))
        XCTAssertNoThrow(try ServiceCatalog.validate([valid(socket: "{run}/s-{port.main}.sock")]))
        assertRejected([valid(socket: "{run}/{port.other}.sock")], "{port.other}")
        assertRejected([valid(socket: "{run}/{name}.sock")], "socket")
        assertRejected([valid(socket: "{run}/{socketDir}.sock")], "socket")
        assertRejected([valid(socket: "{run}/x/{port.main}")], "socket")
        assertRejected([valid(socket: "{run}/x/s.sock")], "socket")
        assertRejected([valid(socket: "{run}/{port.main}/s.sock")], "socket")
        assertRejected([valid(socket: "{run}{port.main}")], "socket")
        XCTAssertTrue(ServiceCatalog.knownPlaceholders.contains("socketDir"))
    }

    func testDisplayNamesLeaveRoomForTheSeries() {
        func named(_ name: String) -> ServiceRecipe {
            ServiceRecipe(kind: "sample", displayName: name, version: "1.0", licence: "MIT", assets: [],
                          start: RecipeCommand(executable: "{bin}/s"), ready: .tcp(port: "{port.main}"),
                          ports: [RecipePort(name: "main", preferred: 4000)])
        }
        XCTAssertNoThrow(try ServiceCatalog.validate([named(String(repeating: "x", count: 48))]))
        assertRejected([named(String(repeating: "x", count: 49))], "48")
    }

    /// Each `:`-separated entry of PHP_INI_SCAN_DIR stays in the instance's folders, like PATH (an empty one
    /// would mean PHP's own compiled-in folder).
    func testPHPIniScanDirIsCheckedPerEntry() {
        func env(_ value: String) -> ServiceRecipe {
            valid(start: RecipeCommand(executable: "{bin}/sample", environment: ["PHP_INI_SCAN_DIR": value]))
        }
        XCTAssertNoThrow(try ServiceCatalog.validate([env("{config}/conf.d:{data}/php")]))
        assertRejected([env("{config}/conf.d:/etc/php.d")], "PHP_INI_SCAN_DIR")
        assertRejected([env("{config}/conf.d:")], "PHP_INI_SCAN_DIR")
        assertRejected([env(":{config}/conf.d")], "PHP_INI_SCAN_DIR")
        assertRejected([env("{bin}/conf.d")], "PHP_INI_SCAN_DIR")
    }

    func testMinimumMacOSIsAVersion() {
        func needing(_ minimum: String) -> ServiceRecipe {
            ServiceRecipe(kind: "sample", displayName: "Sample", version: "1.0", licence: "MIT", minimumMacOS: minimum,
                          assets: [], start: RecipeCommand(executable: "{bin}/s"), ready: .tcp(port: "{port.main}"),
                          ports: [RecipePort(name: "main", preferred: 4000)])
        }
        XCTAssertNoThrow(try ServiceCatalog.validate([needing("15.0")]))
        XCTAssertNoThrow(try ServiceCatalog.validate([needing("13")]))
        for bad in ["", "15.", "x", "15.0.1.2", "15 .0"] { assertRejected([needing(bad)], "minimumMacOS") }
    }

    // MARK: - Actions

    private func withAction(_ action: RecipeAction, named name: String = "createDatabase") -> ServiceRecipe {
        let base = valid()
        return ServiceRecipe(kind: base.kind, displayName: base.displayName, version: base.version, series: base.series,
                             licence: base.licence, assets: base.assets, initialise: base.initialise, start: base.start,
                             ready: base.ready, ports: base.ports, socket: base.socket, env: base.env,
                             configFiles: base.configFiles, actions: [name: action])
    }

    private let database = RecipeParameter(name: "database", pattern: "^[A-Za-z0-9_]{1,63}$")

    private func action(_ executable: String = "{bin}/createdb", arguments: [RecipeArgument] = ["-p", "{port.main}", "{database}"],
                        environment: [String: String] = [:], stdin: String? = nil,
                        parameters: [RecipeParameter]? = nil, alreadyDone: String? = nil) -> RecipeAction {
        RecipeAction(command: RecipeCommand(executable: executable, arguments: arguments, environment: environment, stdin: stdin),
                     parameters: parameters ?? [database], alreadyDone: alreadyDone)
    }

    func testAValidActionPasses() {
        XCTAssertNoThrow(try ServiceCatalog.validate([withAction(action(alreadyDone: "database \"{database}\" already exists"))]))
        XCTAssertNoThrow(try ServiceCatalog.validate([withAction(action(arguments: [.ifSocket(["-h", "{socketDir}"]), "{database}"]))]))
    }

    func testActionsAreKnownByName() {
        assertRejected([withAction(action(), named: "dropEverything")], "dropEverything")
    }

    /// A parameter is free text the user typed: it may only be an argument, never a program, a path variable,
    /// another environment value or standard input.
    func testParametersOnlyInArguments() {
        assertRejected([withAction(action("{bin}/{database}"))], "under {bin}/")
        assertRejected([withAction(action(environment: ["PGDATABASE": "{database}"]))], "{database}")
        assertRejected([withAction(action(environment: ["HOME": "{data}/{database}"]))], "HOME")
        assertRejected([withAction(action(stdin: "create database {database};"))], "{database}")
        assertRejected([valid(env: ["DB={database}"])], "{database}")
        assertRejected([valid(start: RecipeCommand(executable: "{bin}/s", arguments: ["{database}"]))], "{database}")
    }

    func testParametersAreDeclaredWithAWholeValuePattern() {
        assertRejected([withAction(action(parameters: []))], "{database}")
        assertRejected([withAction(action(parameters: [RecipeParameter(name: "database", pattern: "[a-z]+")]))], "pattern")
        assertRejected([withAction(action(parameters: [RecipeParameter(name: "database", pattern: "^[a-z+$")]))], "pattern")
        assertRejected([withAction(action(arguments: ["{data}"], parameters: [RecipeParameter(name: "data", pattern: "^x$")]))],
                       "parameter")
        assertRejected([withAction(action(parameters: [database, database]))], "parameter")
        assertRejected([withAction(action(arguments: ["{dbname}"]))], "{dbname}")
        assertRejected([withAction(action("/usr/bin/createdb"))], "under {bin}/")
    }

    // MARK: - Fix round 1

    /// The service can write to `{data}` and `{run}`: a program there could shadow `sh` for its children.
    func testPATHTakesOnlyTheBinariesAndConfigFolders() {
        func path(_ value: String) -> ServiceRecipe {
            valid(start: RecipeCommand(executable: "{bin}/sample", environment: ["PATH": value]))
        }
        XCTAssertNoThrow(try ServiceCatalog.validate([path("{bin}/bin:{config}/tools")]))
        assertRejected([path("{data}/bin")], "PATH")
        assertRejected([path("{bin}:{run}")], "PATH")
        assertRejected([path("{bin}:{data}")], "PATH")
    }

    /// Lock files hold a pid on their first line; Paddock removes stale ones, so they must be the instance's own.
    func testLockFilesStayInTheDataOrRunFolder() {
        func locks(_ files: [String]) -> ServiceRecipe {
            let base = valid()
            return ServiceRecipe(kind: base.kind, displayName: base.displayName, version: base.version, series: base.series,
                                 licence: base.licence, assets: base.assets, initialise: base.initialise, start: base.start,
                                 ready: base.ready, ports: base.ports, socket: base.socket, env: base.env,
                                 configFiles: base.configFiles, lockFiles: files)
        }
        XCTAssertNoThrow(try ServiceCatalog.validate([locks(["{data}/postmaster.pid", "{run}/.s.PGSQL.{port.main}.lock",
                                                             "{data}/sub/x-{port.main}.pid"])]))
        for bad in ["{config}/x.pid", "/tmp/x.pid", "{data}", "{data}/", "{data}/../x.pid", "{data}/{name}.pid",
                    "{data}/{port.main}/x.pid", "{run}{port.main}", "{bin}/x.pid", "{data}//x"] {
            assertRejected([locks([bad])], "lock file")
        }
        assertRejected([locks(["{run}/{port.other}.lock"])], "{port.other}")
    }

    /// Readiness may be a command (PostgreSQL's pg_isready), held to the same rules as every other command.
    func testAReadinessCommandFollowsTheCommandRules() throws {
        func ready(_ command: RecipeCommand) -> ServiceRecipe {
            ServiceRecipe(kind: "sample", displayName: "Sample", version: "1.0", licence: "MIT", assets: [],
                          start: RecipeCommand(executable: "{bin}/s"), ready: .command(command),
                          ports: [RecipePort(name: "main", preferred: 4000)])
        }
        XCTAssertNoThrow(try ServiceCatalog.validate([ready(RecipeCommand(executable: "{bin}/bin/pg_isready",
                                                                           arguments: ["--port={port.main}", "--quiet"]))]))
        assertRejected([ready(RecipeCommand(executable: "/bin/sh", arguments: ["-c", "true"]))], "under {bin}/")
        assertRejected([ready(RecipeCommand(executable: "{bin}/x", arguments: ["{nope}"]))], "{nope}")
        assertRejected([ready(RecipeCommand(executable: "{bin}/x", environment: ["DYLD_INSERT_LIBRARIES": "{data}/x"]))],
                       "DYLD_")
        assertRejected([ready(RecipeCommand(executable: "{bin}/x", stdin: "x"))], "stdin")
    }

    /// Decoding a catalog validates it, so a bad bundled, hosted or development catalog never loads.
    func testDecodingValidates() throws {
        let bad = ServiceCatalog(recipes: [valid(stopSignal: "KILL")])
        XCTAssertThrowsError(try JSONDecoder().decode(ServiceCatalog.self, from: JSONEncoder().encode(bad)))
    }
}
