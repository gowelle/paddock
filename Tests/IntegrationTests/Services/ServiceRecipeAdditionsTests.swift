import Darwin
import PaddockTestSupport
import XCTest
@testable import PaddockCore

/// What the framework gained for PostgreSQL, with the fake service on free high ports: actions (creating a
/// database) run while the service runs, with validated parameters; the start command's working folder;
/// PATH coming before the base PATH; clean failures for unusable names, missing PHP and too old a macOS; and
/// the loopback check after an automatic restart.
final class ServiceRecipeAdditionsTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []
    private var engine: Engine?

    override func setUpWithError() throws {
        try FakeService.requireBuilt()
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        engine?.shutdown()
        engine = nil
        home?.cleanUp()
    }

    // MARK: - Helpers

    private static let database = RecipeParameter(name: "database", pattern: "^[A-Za-z0-9_]{1,63}$")

    /// `FakeService.createDatabase`, with other parameters or no "already there" output.
    private static func createAction(alreadyDone: String? = "\"{database}\" already exists",
                                     parameters: [RecipeParameter] = [database]) -> RecipeAction {
        RecipeAction(command: FakeService.createDatabase.command, parameters: parameters, alreadyDone: alreadyDone)
    }

    private func fake(environment: [String: String] = [:], actions: [String: RecipeAction] = [:],
                      minimumMacOS: String? = nil, displayName: String = "Fake", series: String? = nil,
                      seriesInID: Bool = false, extraArguments: [String] = []) -> ServiceRecipe {
        let base = FakeService.recipe(series: series, seriesInID: seriesInID, displayName: displayName,
                                      extraArguments: extraArguments)
        return ServiceRecipe(kind: base.kind, displayName: base.displayName, version: base.version, series: base.series,
                             seriesInID: base.seriesInID, licence: base.licence, minimumMacOS: minimumMacOS,
                             assets: base.assets, initialise: base.initialise,
                             start: RecipeCommand(executable: base.start.executable, arguments: base.start.arguments,
                                                  environment: environment),
                             ready: base.ready, stopSignal: base.stopSignal, stopGraceSeconds: base.stopGraceSeconds,
                             ports: base.ports, socket: base.socket, env: base.env, openURL: base.openURL,
                             configFiles: base.configFiles, actions: actions)
    }

    private func makeManager(_ recipes: [ServiceRecipe], phpBinary: URL? = nil, lateChecks: [TimeInterval] = [],
                             macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.05),
                                     portCheck: .withoutProbes, phpBinary: { phpBinary }, portBase: home.portBase,
                                     lateLoopbackChecks: lateChecks, macOSVersion: macOS)
        managers.append(manager)
        return manager
    }

    private func serviceError(_ body: () async throws -> Void) async -> ServiceError? {
        do { try await body(); return nil } catch { return error as? ServiceError }
    }

    private func status(_ manager: ServiceManager, _ id: String = "fake") -> ServiceStatus? {
        manager.statuses().first { $0.id == id }
    }

    private func made(_ database: String) -> Bool {
        FileManager.default.fileExists(atPath: home.paths.serviceData("fake").appendingPathComponent("made-\(database)").path)
    }

    private func recorded(_ file: String) -> String? {
        try? String(contentsOf: home.paths.serviceData("fake").appendingPathComponent(file), encoding: .utf8)
    }

    // MARK: - Actions

    func testCreateDatabaseRunsTheRecipesActionWhileTheServiceRuns() async throws {
        let manager = makeManager([fake(actions: [RecipeAction.createDatabase: Self.createAction()])])
        _ = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(try manager.createDatabase("fake", database: "shop_1"), .done)
        XCTAssertTrue(made("shop_1"))
        XCTAssertEqual(recorded("action-cwd"), ServiceManager.realPath(home.paths.serviceHome("fake").path),
                       "actions run in the instance's folder, like every step")
        XCTAssertEqual(try manager.createDatabase("Fake", database: "shop_1"), .alreadyDone, "already there is no error")
        XCTAssertTrue(manager.logTail("fake").contains("made shop_1"), "an action's output goes to the service's log")

        manager.stop("fake")
        XCTAssertThrowsError(try manager.createDatabase("fake", database: "other")) { error in
            XCTAssertEqual(error as? ServiceError, .notRunning(name: "Fake", id: "fake"))
        }
        XCTAssertFalse(made("other"))
        XCTAssertThrowsError(try manager.createDatabase("nope", database: "other")) { error in
            XCTAssertEqual(error as? ServiceError, .unknownService("nope"))
        }
    }

    /// Anything but letters, digits and underscores (1 to 63) is refused before anything runs, whatever the
    /// recipe's own pattern says; and the recipe's pattern is applied too.
    func testInvalidDatabaseNamesAreRefusedWithoutRunningAnything() async throws {
        let strict = RecipeParameter(name: "database", pattern: "^[a-z]{1,8}$")
        let manager = makeManager([fake(actions: [RecipeAction.createDatabase: Self.createAction(parameters: [strict])])])
        _ = try await manager.add(kind: "fake", version: nil)
        for bad in ["", "a-b", "-h", "x y", "a;b", "ü", "a\nb", "{data}", String(repeating: "a", count: 64), "Shop", "abcdefghi"] {
            XCTAssertThrowsError(try manager.createDatabase("fake", database: bad), bad) { error in
                XCTAssertEqual(error as? ServiceError, .invalidParameter(parameter: "database", value: bad), bad)
            }
        }
        XCTAssertNil(recorded("action-cwd"), "nothing ran")
        XCTAssertEqual(Messages.serviceError(.invalidParameter(parameter: "database", value: "a-b")),
                       "Database names can use letters, numbers and underscores.")
    }

    func testARecipeWithoutTheActionHasNoDatabases() async throws {
        let manager = makeManager([fake()])
        _ = try await manager.add(kind: "fake", version: nil)
        XCTAssertThrowsError(try manager.createDatabase("fake", database: "shop")) { error in
            guard let error = error as? ServiceError else { return XCTFail("\(error)") }
            XCTAssertEqual(error, .noAction(name: "Fake", action: RecipeAction.createDatabase))
            XCTAssertEqual(Engine.response(for: error), .error(code: ErrorCode.serviceUnavailable,
                                                               message: "Fake doesn't have databases."))
        }
    }

    func testAFailingActionReportsItsOutput() async throws {
        let manager = makeManager([fake(actions: [RecipeAction.createDatabase: Self.createAction(alreadyDone: nil)])])
        _ = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(try manager.createDatabase("fake", database: "shop"), .done)
        XCTAssertThrowsError(try manager.createDatabase("fake", database: "shop")) { error in
            guard case .actionFailed(let name, let action, let output)? = error as? ServiceError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, "Fake")
            XCTAssertEqual(action, RecipeAction.createDatabase)
            XCTAssertTrue(output.contains("\"shop\" already exists"), output)
            XCTAssertEqual(Engine.response(for: error as! ServiceError).errorCode, ErrorCode.serviceFailed)
        }
    }

    func testCreateDatabaseThroughTheEngine() async throws {
        var settings = Settings()
        settings.httpPort = TestSupport.freeTCPPort()
        settings.httpsPort = TestSupport.freeTCPPort(excluding: [settings.httpPort])
        settings.dnsPort = TestSupport.freeUDPPort(preferred: 53597)
        let recipe = fake(actions: [RecipeAction.createDatabase: Self.createAction()])
        let engine = Engine(paths: home.paths, settings: settings, installAction: nil, managesPortHelper: true,
                            portHelper: TestSupport.portHelper, portHolders: TestSupport.portHoldersWithoutProbes,
                            serviceSetup: ServiceSetup(catalog: ServiceCatalog(recipes: [recipe]), portBase: home.portBase,
                                                       portCheck: .withoutProbes),
                            log: { _ in })
        self.engine = engine
        guard case .ok = await engine.handle(.serviceAdd(kind: "fake", version: nil)) else { return XCTFail("add") }
        guard case .databaseCreated(let database, let existed, let status) =
                await engine.handle(.serviceCreateDatabase(name: "fake", database: "shop")) else { return XCTFail("create") }
        XCTAssertEqual(database, "shop")
        XCTAssertFalse(existed)
        XCTAssertEqual(status.services.map(\.id), ["fake"])
        guard case .databaseCreated(_, true, _) = await engine.handle(.serviceCreateDatabase(name: "fake", database: "shop"))
        else { return XCTFail("again") }
        let refused = await engine.handle(.serviceCreateDatabase(name: "fake", database: "no way"))
        XCTAssertEqual(refused, .error(code: ErrorCode.invalidArgument, message: "Database names can use letters, numbers and underscores."))
    }

    // MARK: - How the start command runs

    func testTheStartCommandRunsInTheInstanceFolder() async throws {
        let manager = makeManager([fake()])
        _ = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(recorded("cwd"), ServiceManager.realPath(home.paths.serviceHome("fake").path))
    }

    func testARecipesPATHComesBeforeTheBasePATH() async throws {
        let manager = makeManager([fake(environment: ["PATH": "{bin}:{config}/tools"])])
        _ = try await manager.add(kind: "fake", version: nil)
        let bin = home.paths.serviceBin(kind: "fake", version: "1.0").path
        let config = home.paths.serviceConfig("fake").path
        XCTAssertTrue(FakeService.environment(paths: home.paths, id: "fake")
            .contains("PATH=\(bin):\(config)/tools:/usr/bin:/bin:/usr/sbin:/sbin"),
                      "\(FakeService.environment(paths: home.paths, id: "fake"))")
    }

    // MARK: - Clean failures

    /// A display name of 48 characters and a long series make a name Paddock can't use: the add fails at once
    /// and saves nothing, rather than saving an instance it would then ignore.
    func testAnUnusableInstanceNameFailsTheAddCleanly() async throws {
        let series = "1234567890123456"
        let manager = makeManager([fake(displayName: String(repeating: "x", count: 48), series: series, seriesInID: true)])
        let error = await serviceError { _ = try await manager.add(kind: "fake", version: nil) }
        guard case .unavailable(_, let reason)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(reason.contains("name"), reason)
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceHome("fake-\(series)").path))
    }

    func testAPHPRecipeWithoutPHPSaysSo() async throws {
        let php = home.paths.phpDir(PHPVersion("8.5")!).appendingPathComponent("php")
        try FileManager.default.createDirectory(at: php.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FakeService.binary, to: php)
        let recipe = ServiceRecipe(
            kind: "phpfake", displayName: "PHP Fake", version: "1.0", seriesInID: false, licence: "MIT", assets: [],
            start: RecipeCommand(executable: "{php}", arguments: ["serve", "{data}", "--port", "{port.main}"]),
            ready: .tcp(port: "{port.main}"), ports: [RecipePort(name: "main", preferred: 1200)], needsPHP: true)
        let first = makeManager([recipe], phpBinary: php)
        _ = try await first.add(kind: "phpfake", version: nil)
        first.stopAll()

        let withoutPHP = makeManager([recipe], phpBinary: nil)
        XCTAssertThrowsError(try withoutPHP.start("phpfake")) { error in
            XCTAssertEqual(error as? ServiceError, .unavailable(name: "PHP Fake", reason: "it runs on PHP, and no PHP is installed"))
        }
        XCTAssertEqual(status(withoutPHP, "phpfake")?.state, .unavailable(reason: "it runs on PHP, and no PHP is installed"))
    }

    func testAServiceNeedingANewerMacOSIsRefused() async throws {
        let manager = makeManager([fake(minimumMacOS: "15.0")],
                                  macOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0))
        let error = await serviceError { _ = try await manager.add(kind: "fake", version: nil) }
        XCTAssertEqual(error, .needsNewerMacOS(name: "Fake", minimum: "15.0"))
        guard let error else { return XCTFail("added") }
        XCTAssertEqual(Engine.response(for: error), .error(code: ErrorCode.serviceUnavailable,
                                                            message: "Fake needs macOS 15 or later."))
        XCTAssertEqual(StateStore(paths: home.paths).load().services, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.serviceBin(kind: "fake", version: "1.0").path),
                       "nothing downloaded")

        let current = makeManager([fake(minimumMacOS: "15.0")],
                                  macOS: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        _ = try await current.add(kind: "fake", version: nil)
    }

    // MARK: - After an automatic restart

    /// The first process dies before it opens a listener beyond this Mac; the supervisor restarts it, and the
    /// restarted one does open it. The checks tied to the first launch skip the new process; the restart's own
    /// checks catch it.
    func testTheLoopbackCheckFollowsAnAutomaticRestart() async throws {
        let late = TestSupport.freeTCPPort(excluding: [home.fakePort])
        let manager = makeManager([fake(extraArguments: ["--late-listen", "\(late)", "--late-delay", "2000"])],
                                  lateChecks: [4])
        _ = try await manager.add(kind: "fake", version: nil)
        let first = try XCTUnwrap(manager.processes["service-fake"].flatMap(TestSupport.pid(from:)))
        kill(first, SIGKILL)
        XCTAssertTrue(waitFor(10) {
            guard let pid = manager.processes["service-fake"].flatMap(TestSupport.pid(from:)) else { return false }
            return pid != first
        }, "restarted by the supervisor")
        XCTAssertTrue(waitFor(20) { self.status(manager)?.notice != nil }, "the restart was checked")
        XCTAssertEqual(status(manager)?.notice, "Fake tried to listen on *:\(late), which is not this Mac only. Paddock stopped it.")
        XCTAssertNotEqual(status(manager)?.state, .running)
        XCTAssertFalse(PortCheck.acceptsIPv4(port: late))
    }
}

private extension Response {
    var errorCode: String? {
        if case .error(let code, _) = self { return code }
        return nil
    }
}
