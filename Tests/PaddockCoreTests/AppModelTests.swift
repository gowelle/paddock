import XCTest
@testable import PaddockCore

/// A daemon stand-in: answers from `handler`, records requests, and can hold a request until released.
private final class FakeClient: ClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Request] = []
    var handler: @Sendable (Request) throws -> Response
    /// When set, every request other than `status` waits for it before answering.
    var gate: DispatchSemaphore?

    init(_ handler: @escaping @Sendable (Request) throws -> Response) {
        self.handler = handler
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ r: Request) throws -> Response {
        lock.lock()
        recorded.append(r)
        let gate = r == .status ? nil : self.gate
        lock.unlock()
        gate?.wait()
        return try handler(r)
    }
}

private final class FakeServices: AppServices, @unchecked Sendable {
    var isSystemIntegrationEnabled = true
    var startsAtLogin = false
    var isShellConfigured = false
    var parked: [String] = ["/Users/someone/Paddock"]
    var startCalls = 0
    var stopCalls = 0
    var startOutcome: DaemonLauncher.Outcome = .viaSystem
    var startError: Error?
    var loginSettings: [Bool] = []
    var restoreLines = ["Paddock is uninstalled."]
    var restoreCalls = 0

    func startDaemon() throws -> DaemonLauncher.Outcome {
        startCalls += 1
        if let startError { throw startError }
        return startOutcome
    }
    func stopDaemon() throws { stopCalls += 1 }
    func setStartsAtLogin(_ on: Bool) throws {
        loginSettings.append(on)
        startsAtLogin = on
    }
    func restorePreviousSetup() throws -> [String] {
        restoreCalls += 1
        return restoreLines
    }
    func configureShell() throws { isShellConfigured = true }
    func parkedFolders() -> [String] { parked }
}

private struct FakeQuitter: ApplicationQuitter {
    var quittable: Set<Int32> = []
    func canQuit(pid: Int32) -> Bool { quittable.contains(pid) }
    func quit(pid: Int32) -> Bool { quittable.contains(pid) }
}

private struct SomeError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

private let v84 = PHPVersion(major: 8, minor: 4)
private let v85 = PHPVersion(major: 8, minor: 5)

private func sampleStatus(running: Bool = true, blockedBy: [PortHolder] = [], sites: [Site]? = nil) -> EngineStatus {
    EngineStatus(running: running, blockedBy: blockedBy,
                 sites: sites ?? [Site(name: "blog", path: "/p/blog", kind: .parked, secured: true,
                                       php: v85, pinned: false)],
                 installedPHP: [v84, v85], defaultPHP: v85, processes: [:],
                 resolverInstalled: true, trustEnabled: true)
}

@MainActor
final class AppModelTests: XCTestCase {
    // MARK: - Step 1 behaviours

    func testRefreshPublishesStatus() async {
        let expected = sampleStatus()
        let model = AppModel(client: FakeClient { _ in .ok(expected) })
        XCTAssertNil(model.status)
        await model.refresh()
        XCTAssertEqual(model.status, expected)
        XCTAssertNil(model.lastError)
    }

    func testErrorResponseSetsLastErrorAndLeavesStatusUnchanged() async {
        let initial = sampleStatus()
        let client = FakeClient { _ in .ok(initial) }
        let model = AppModel(client: client)
        await model.refresh()
        client.handler = { _ in .error(code: ErrorCode.unknownSite, message: "Paddock doesn't serve a site named nope.") }
        await model.perform(.secure(site: "nope"))
        XCTAssertEqual(model.lastError, "Paddock doesn't serve a site named nope.")
        XCTAssertEqual(model.status, initial)
    }

    func testPerformMarksTheActionBusyAndClearsIt() async throws {
        let client = FakeClient { _ in .ok(sampleStatus()) }
        let gate = DispatchSemaphore(value: 0)
        client.gate = gate
        let model = AppModel(client: client)
        let install = Request.installPHP(version: v84)
        XCTAssertFalse(model.isBusy(install))

        let task = Task { await model.perform(install) }
        let deadline = Date().addingTimeInterval(5)
        while !model.isBusy(install) && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.isBusy(install))
        XCTAssertFalse(model.isBusy(.installPHP(version: v85)))

        gate.signal()
        await task.value
        XCTAssertFalse(model.isBusy(install))
        XCTAssertTrue(model.busy.isEmpty)
        XCTAssertEqual(client.requests.first, install)
    }

    func testBlockedStatusExposesTheHolderForTheMenuLine() async {
        let holder = PortHolder(port: 80, pid: 123, command: "nginx", ownedByCurrentUser: true)
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(running: false, blockedBy: [holder])) },
                             quitter: FakeQuitter(quittable: [123]))
        await model.refresh()
        XCTAssertEqual(model.blockingHolder, holder)
        XCTAssertEqual(model.statusLine, "Can't start: port 80 in use by nginx")
        XCTAssertTrue(model.canQuitBlockingHolder)
        XCTAssertEqual(model.quitButtonTitle, "Quit nginx")
        XCTAssertNil(model.blockedExplanation)
    }

    // MARK: - Derived properties

    func testStatusLineRunningAndStopped() async {
        let client = FakeClient { _ in .ok(sampleStatus()) }
        let model = AppModel(client: client)
        XCTAssertEqual(model.statusLine, "Stopped")
        XCTAssertFalse(model.isRunning)
        await model.refresh()
        XCTAssertEqual(model.statusLine, "Running")
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.blockingHolder)

        client.handler = { _ in .ok(sampleStatus(running: false)) }
        await model.refresh()
        XCTAssertEqual(model.statusLine, "Stopped")
    }

    func testDaemonNotRunningMeansStoppedWithoutAnError() async {
        let client = FakeClient { _ in .ok(sampleStatus()) }
        let model = AppModel(client: client)
        await model.refresh()
        client.handler = { _ in throw ClientError.daemonNotRunning }
        await model.refresh()
        XCTAssertNil(model.status)
        XCTAssertEqual(model.statusLine, "Stopped")
        XCTAssertNil(model.lastError)
    }

    func testHolderNotOwnedByUserGetsTheSentenceAndNoButton() async {
        let holder = PortHolder(port: 80, pid: 44, command: "nginx", ownedByCurrentUser: false)
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(running: false, blockedBy: [holder])) },
                             quitter: FakeQuitter(quittable: [44]))
        await model.refresh()
        XCTAssertFalse(model.canQuitBlockingHolder)
        XCTAssertEqual(model.blockedExplanation, Messages.portsBlocked([holder]))
    }

    func testOwnedHolderThatIsNotAnApplicationGetsNoButton() async {
        let holder = PortHolder(port: 443, pid: 77, command: nil, ownedByCurrentUser: true)
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(running: false, blockedBy: [holder])) },
                             quitter: FakeQuitter())
        await model.refresh()
        XCTAssertEqual(model.statusLine, "Can't start: port 443 in use by another program")
        XCTAssertFalse(model.canQuitBlockingHolder)
        XCTAssertEqual(model.blockedExplanation, Messages.portsBlocked([holder]))
    }

    func testQuitBlockingHolderQuitsOnlyThatPidThenStarts() async {
        let holder = PortHolder(port: 80, pid: 123, command: "nginx", ownedByCurrentUser: true)
        let client = FakeClient { _ in .ok(sampleStatus(running: false, blockedBy: [holder])) }
        let model = AppModel(client: client, quitter: FakeQuitter(quittable: [123]))
        await model.refresh()
        client.handler = { _ in .ok(sampleStatus()) }
        await model.quitBlockingHolder()
        XCTAssertTrue(client.requests.contains(.start))
        XCTAssertEqual(model.statusLine, "Running")
    }

    func testSitesAndPHPListsForTheViews() async {
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus()) },
                             availablePHP: [PHPVersion(major: 8, minor: 1), v84, v85])
        XCTAssertEqual(model.sites, [])
        XCTAssertEqual(model.phpMenuTitle, "PHP")
        await model.refresh()
        XCTAssertEqual(model.sites.map(\.name), ["blog"])
        XCTAssertEqual(model.installedPHP, [v84, v85])
        XCTAssertEqual(model.defaultPHP, v85)
        XCTAssertEqual(model.availablePHP.map(\.description), ["8.1", "8.4", "8.5"])
        XCTAssertEqual(model.phpMenuTitle, "PHP 8.5")
        XCTAssertEqual(model.defaultPHPLabel, "Default (8.5)")
    }

    func testSuccessfulActionClearsTheLastError() async {
        let client = FakeClient { _ in .error(code: ErrorCode.internal, message: "nope") }
        let model = AppModel(client: client)
        await model.perform(.use(version: v84))
        XCTAssertEqual(model.lastError, "nope")
        client.handler = { _ in .ok(sampleStatus()) }
        await model.perform(.use(version: v84))
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.status, sampleStatus())
    }

    func testTrustErrorsGoToTheSitesNoticeNotTheErrorLine() async {
        let client = FakeClient { r in
            if case .secure = r { return .error(code: ErrorCode.needsTrust, message: "blog.test needs trust") }
            return .ok(sampleStatus())
        }
        let model = AppModel(client: client)
        await model.perform(.secure(site: "blog"))
        XCTAssertEqual(model.trustNotice, "blog.test needs trust")
        XCTAssertNil(model.lastError)
        // The site was still secured, so the model refreshed after the action.
        XCTAssertEqual(model.status, sampleStatus())

        client.handler = { r in
            if case .secure = r { return .error(code: ErrorCode.trustDisabled, message: Messages.trustDisabled) }
            return .ok(sampleStatus())
        }
        await model.perform(.secure(site: "blog"))
        XCTAssertEqual(model.trustNotice, Messages.trustDisabled)
        client.handler = { _ in .ok(sampleStatus()) }
        await model.perform(.unsecure(site: "blog"))
        XCTAssertNil(model.trustNotice)
    }

    func testPortsBlockedOnStartIsShownByTheStatusLineNotTheErrorLine() async {
        let holder = PortHolder(port: 80, pid: 9, command: "httpd", ownedByCurrentUser: false)
        let client = FakeClient { r in
            if r == .start { return .error(code: ErrorCode.portsBlocked, message: "Port 80 is in use by httpd (pid 9)") }
            return .ok(sampleStatus(running: false, blockedBy: [holder]))
        }
        let services = FakeServices()
        let model = AppModel(client: client, services: services)
        await model.start()
        XCTAssertEqual(services.startCalls, 1)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.statusLine, "Can't start: port 80 in use by httpd")
    }

    func testStartGoesThroughTheLauncherThenAsksTheEngineToStart() async {
        let client = FakeClient { _ in .ok(sampleStatus()) }
        let services = FakeServices()
        services.startOutcome = .spawned
        let model = AppModel(client: client, services: services)
        await model.start()
        XCTAssertEqual(services.startCalls, 1)
        XCTAssertEqual(client.requests.filter { $0 == .start }.count, 1)
        XCTAssertTrue(model.ownsDaemon)
        XCTAssertEqual(model.statusLine, "Running")
    }

    func testStartFailureIsOneQuietLine() async {
        let services = FakeServices()
        services.startError = SomeError()
        let model = AppModel(client: FakeClient { _ in throw ClientError.daemonNotRunning }, services: services)
        await model.start()
        XCTAssertEqual(model.lastError, "Couldn't start Paddock: boom")
        XCTAssertEqual(model.statusLine, "Stopped")
    }

    func testLaunchStartsOnlyWhenTheDaemonIsNotRunning() async {
        let services = FakeServices()
        let running = AppModel(client: FakeClient { _ in .ok(sampleStatus()) }, services: services)
        await running.launch()
        XCTAssertEqual(services.startCalls, 0)

        let client = FakeClient { _ in throw ClientError.daemonNotRunning }
        let stopped = AppModel(client: client, services: services)
        services.startError = SomeError()
        await stopped.launch()
        XCTAssertEqual(services.startCalls, 1)
    }

    func testStopUsesTheServicesAndShowsStopped() async {
        let client = FakeClient { _ in .ok(sampleStatus()) }
        let services = FakeServices()
        let model = AppModel(client: client, services: services)
        await model.refresh()
        client.handler = { _ in throw ClientError.daemonNotRunning }
        await model.stop()
        XCTAssertEqual(services.stopCalls, 1)
        XCTAssertEqual(model.statusLine, "Stopped")
    }

    func testSystemFeaturesAreDisabledForADevelopmentHome() async {
        let services = FakeServices()
        services.isSystemIntegrationEnabled = false
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus()) }, services: services)
        XCTAssertFalse(model.systemIntegrationEnabled)
        XCTAssertEqual(AppModel.unavailableCaption, "Not available for this Paddock home.")
        await model.setStartsAtLogin(true)
        await model.restorePreviousSetup()
        XCTAssertEqual(services.loginSettings, [])
        XCTAssertEqual(services.restoreCalls, 0)
    }

    func testStartAtLoginAndRestore() async {
        let services = FakeServices()
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus()) }, services: services)
        await model.refresh()
        XCTAssertFalse(model.startsAtLogin)
        await model.setStartsAtLogin(true)
        XCTAssertTrue(model.startsAtLogin)
        XCTAssertEqual(services.loginSettings, [true])

        await model.restorePreviousSetup()
        XCTAssertEqual(services.restoreCalls, 1)
        XCTAssertEqual(model.restoreMessage, "Paddock is uninstalled.")
    }

    func testRestoreAlsoStopsADaemonTheAppLaunched() async {
        let services = FakeServices()
        services.startOutcome = .spawned
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus()) }, services: services)
        await model.start()
        XCTAssertTrue(model.ownsDaemon)
        await model.restorePreviousSetup()
        XCTAssertEqual(services.stopCalls, 1)
        XCTAssertFalse(model.ownsDaemon)
    }

    func testRefreshReadsParkedFoldersAndShellState() async {
        let services = FakeServices()
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus()) }, services: services)
        await model.refresh()
        XCTAssertEqual(model.parked, ["/Users/someone/Paddock"])
        XCTAssertEqual(model.sitesFolder?.path, "/Users/someone/Paddock")
        XCTAssertFalse(model.shellConfigured)
        await model.addToTerminal()
        XCTAssertTrue(model.shellConfigured)
    }

    func testPHPIniIsOfferedOnlyOnceItExists() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("appmodel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus()) }, paths: paths)
        XCTAssertNil(model.phpIni(v84))
        try FileManager.default.createDirectory(at: paths.phpIni(v84).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: paths.phpIni(v84))
        XCTAssertEqual(model.phpIni(v84), paths.phpIni(v84))
    }

    func testOwnedDaemonIsShutDownOnQuit() async {
        let client = FakeClient { _ in .ok(sampleStatus()) }
        let services = FakeServices()
        services.startOutcome = .spawned
        let model = AppModel(client: client, services: services)
        model.shutDownOwnedDaemon()
        XCTAssertFalse(client.requests.contains(.shutdown))
        await model.start()
        model.shutDownOwnedDaemon()
        XCTAssertTrue(client.requests.contains(.shutdown))
    }
}
