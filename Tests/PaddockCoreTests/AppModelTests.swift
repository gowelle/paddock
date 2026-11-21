import XCTest
@testable import PaddockCore

/// A daemon stand-in: answers from `handler`, records requests, and can hold a request until released.
private final class FakeClient: ClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var recordedTimeouts: [TimeInterval] = []
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

    /// The timeout each request was sent with, in order.
    var timeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTimeouts
    }

    func send(_ r: Request, timeout: TimeInterval) throws -> Response {
        lock.lock()
        recorded.append(r)
        recordedTimeouts.append(timeout)
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
    func configureShell() throws { configureCalls += 1; isShellConfigured = true }
    func parkedFolders() -> [String] { parked }
    /// Set to refuse every system change, as a development build on the real system does.
    var refusal: Error?
    var configureCalls = 0
    func checkMayChangeSystem() throws { if let refusal { throw refusal } }
}

/// Pretends the applications at `quittable` are running for this user. Never quits anything real.
private final class FakeQuitter: ApplicationQuitter, @unchecked Sendable {
    let quittable: Set<String>
    private(set) var quitRequests: [String] = []
    init(quittable: Set<String> = []) { self.quittable = quittable }
    func canQuit(appBundlePath: String) -> Bool { quittable.contains(appBundlePath) }
    func quit(appBundlePath: String) -> Bool {
        quitRequests.append(appBundlePath)
        return quittable.contains(appBundlePath)
    }
}

private let herdApp = "/Applications/Herd.app"

/// Herd's nginx: 4 worker pids listening on each of 80 and 443.
private func herdHolders() -> [PortHolder] {
    [80, 443].flatMap { port in
        (101...104).map { PortHolder(port: port, pid: Int32($0), command: "nginx-x86", ownedByCurrentUser: true,
                                     executablePath: herdApp + "/Contents/Resources/nginx-x86") }
    }
}

private struct SomeError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

private let v84 = PHPVersion(major: 8, minor: 4)
private let v85 = PHPVersion(major: 8, minor: 5)

private func sampleStatus(running: Bool = true, blockedBy: [PortHolder] = [],
                          sites: [Site]? = nil, portHelperInstalled: Bool = true,
                          needsTrust: Bool = false, hasReplacedRootsToClean: Bool = false) -> EngineStatus {
    EngineStatus(running: running, blockedBy: blockedBy,
                 sites: sites ?? [Site(name: "blog", path: "/p/blog", kind: .parked, secured: true,
                                       php: v85, pinned: false)],
                 installedPHP: [v84, v85], defaultPHP: v85, processes: [:],
                 resolverInstalled: true, trustEnabled: true, dnsRunning: true,
                 portHelperInstalled: portHelperInstalled, needsTrust: needsTrust,
                 hasReplacedRootsToClean: hasReplacedRootsToClean)
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
                             quitter: FakeQuitter())
        await model.refresh()
        XCTAssertEqual(model.blockingHolder, holder)
        XCTAssertEqual(model.statusLine, "Can't start: port 80 in use by nginx")
        XCTAssertFalse(model.canQuitBlockingHolder, "a program outside any application gets no button")
        XCTAssertEqual(model.blockedExplanation, "Paddock can't start: port 80 is in use by nginx (pid 123).")
    }

    func testAnAppHoldingBothPortsGetsOneLineAndAQuitButtonForTheApp() async {
        let quitter = FakeQuitter(quittable: [herdApp])
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(running: false, blockedBy: herdHolders())) },
                             quitter: quitter)
        await model.refresh()
        XCTAssertEqual(model.statusLine, "Can't start: ports 80 and 443 in use by Herd")
        XCTAssertTrue(model.canQuitBlockingHolder)
        XCTAssertEqual(model.quitButtonTitle, "Quit Herd")
        XCTAssertNil(model.blockedExplanation)
        XCTAssertEqual(quitter.quitRequests, [], "nothing is quit until the user clicks")
    }

    func testAnAppThatIsNotRunningForThisUserGetsNoButton() async {
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(running: false, blockedBy: herdHolders())) },
                             quitter: FakeQuitter())
        await model.refresh()
        XCTAssertFalse(model.canQuitBlockingHolder)
        XCTAssertEqual(model.blockedExplanation, "Paddock can't start: ports 80 and 443 are in use by Herd.")
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
                             quitter: FakeQuitter(quittable: [herdApp]))
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

    func testQuitBlockingHolderQuitsOnlyThatAppThenStarts() async {
        let client = FakeClient { _ in .ok(sampleStatus(running: false, blockedBy: herdHolders())) }
        let quitter = FakeQuitter(quittable: [herdApp])
        let model = AppModel(client: client, quitter: quitter)
        await model.refresh()
        client.handler = { _ in .ok(sampleStatus()) }
        await model.quitBlockingHolder()
        XCTAssertEqual(quitter.quitRequests, [herdApp])
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

    func testShutdownOnQuitWaitsOnlyBrieflyAndGivesUpQuietly() async {
        let client = FakeClient { r in
            if r == .shutdown { throw ClientError.timedOut } // A busy daemon: still installing PHP.
            return .ok(sampleStatus())
        }
        let services = FakeServices()
        services.startOutcome = .spawned
        let model = AppModel(client: client, services: services)
        await model.start()
        XCTAssertNil(model.lastError)

        model.shutDownOwnedDaemon()
        XCTAssertEqual(client.requests.last, .shutdown)
        XCTAssertEqual(client.timeouts.last, 5)
        XCTAssertEqual(AppModel.shutdownTimeout, 5)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.ownsDaemon)
        // Ordinary requests keep the long wait.
        XCTAssertEqual(client.timeouts.first, 600)
    }

    func testRefreshErrorIsClearedByTheNextSuccessfulRefresh() async {
        let client = FakeClient { _ in throw ClientError.timedOut }
        let model = AppModel(client: client)
        await model.refresh()
        XCTAssertEqual(model.lastError, Messages.didNotAnswer)
        client.handler = { _ in .ok(sampleStatus()) }
        await model.refresh()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.status, sampleStatus())
    }

    func testActionErrorSurvivesBackgroundRefreshesUntilTheNextSuccessfulAction() async {
        let client = FakeClient { r in
            if case .use = r { return .error(code: ErrorCode.phpNotInstalled, message: "PHP 8.4 isn't installed.") }
            return .ok(sampleStatus())
        }
        let model = AppModel(client: client)
        await model.perform(.use(version: v84))
        XCTAssertEqual(model.lastError, "PHP 8.4 isn't installed.")
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(model.lastError, "PHP 8.4 isn't installed.")

        // A failing refresh doesn't replace it either.
        client.handler = { _ in throw ClientError.timedOut }
        await model.refresh()
        XCTAssertEqual(model.lastError, "PHP 8.4 isn't installed.")

        client.handler = { _ in .ok(sampleStatus()) }
        await model.perform(.use(version: v85))
        XCTAssertNil(model.lastError)
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

    // MARK: - Finishing setup on the real system

    func testRunningWithoutThePortHelperNeedsSetup() async {
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) })
        await model.refresh()
        XCTAssertTrue(model.needsSetup)
        XCTAssertFalse(model.isServing)
        XCTAssertEqual(model.statusLine, "Setup needed")
        XCTAssertEqual(AppModel.finishSetupTitle, "Finish Setup\u{2026}")
    }

    func testADevelopmentHomeOrAFinishedSetupIsJustRunning() async {
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(portHelperInstalled: true)) })
        await model.refresh()
        XCTAssertFalse(model.needsSetup)
        XCTAssertTrue(model.isServing)
        XCTAssertEqual(model.statusLine, "Running")
    }

    func testAStoppedEngineWithoutTheHelperIsStoppedNotSetupNeeded() async {
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(running: false, portHelperInstalled: false)) })
        await model.refresh()
        XCTAssertFalse(model.needsSetup)
        XCTAssertEqual(model.statusLine, "Stopped")
    }

    func testFinishSetupRunsTheStartPath() async {
        let client = FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) }
        let services = FakeServices()
        let model = AppModel(client: client, services: services)
        await model.refresh()
        client.handler = { _ in .ok(sampleStatus()) }
        await model.finishSetup()
        XCTAssertEqual(services.startCalls, 1)
        XCTAssertTrue(client.requests.contains(.start))
        XCTAssertEqual(model.statusLine, "Running")
    }

    func testPortsHeldBeforeTheSetupPromptAreShownWithAQuitButton() async {
        let client = FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) }
        let services = FakeServices()
        services.startError = DaemonLaunchError.portsBlocked(herdHolders())
        let quitter = FakeQuitter(quittable: [herdApp])
        let model = AppModel(client: client, services: services, quitter: quitter)
        await model.start()
        XCTAssertNil(model.lastError, "the status line says it")
        XCTAssertEqual(model.statusLine, "Can't start: ports 80 and 443 in use by Herd")
        XCTAssertTrue(model.isBlocked)
        XCTAssertTrue(model.canQuitBlockingHolder)
        XCTAssertEqual(model.quitButtonTitle, "Quit Herd")
        XCTAssertEqual(client.requests.filter { $0 == .start }, [], "the engine isn't asked to start")

        // Herd quits; the next start finishes setup.
        services.startError = nil
        client.handler = { _ in .ok(sampleStatus()) }
        await model.quitBlockingHolder()
        XCTAssertEqual(quitter.quitRequests, [herdApp])
        XCTAssertFalse(model.isBlocked)
        XCTAssertEqual(model.statusLine, "Running")
    }

    func testPortsHeldBeforeThePromptByANonAppGetTheSentence() async {
        let holder = PortHolder(port: 80, pid: nil, command: nil, ownedByCurrentUser: false)
        let services = FakeServices()
        services.startError = DaemonLaunchError.portsBlocked([holder])
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) },
                             services: services, quitter: FakeQuitter())
        await model.start()
        XCTAssertEqual(model.blockedExplanation, Messages.portsBlocked([holder]))
    }

    func testARootServerNamedByLaunchdGetsTheSentenceAndNoQuitButton() async {
        let holder = PortHolder(port: 80, pid: nil, command: nil, ownedByCurrentUser: false,
                                serverHeader: "nginx/1.30.6", serviceName: "MacPorts nginx",
                                stopCommand: "sudo port unload nginx")
        let services = FakeServices()
        services.startError = DaemonLaunchError.portsBlocked([holder])
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) },
                             services: services, quitter: FakeQuitter(quittable: ["/opt/local"]))
        await model.start()
        XCTAssertFalse(model.canQuitBlockingHolder)
        XCTAssertEqual(model.blockedExplanation, "Paddock can't start: port 80 is in use by MacPorts nginx "
                       + "(nginx/1.30.6). Stop it with: sudo port unload nginx")
        XCTAssertEqual(model.statusLine, "Can't start: port 80 in use by MacPorts nginx (nginx/1.30.6)")
    }

    // MARK: - Retrying setup

    func testSetupActionIsOfferedEvenWithAQuitButton() async {
        let services = FakeServices()
        services.startError = DaemonLaunchError.portsBlocked(herdHolders())
        let model = AppModel(client: FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) },
                             services: services, quitter: FakeQuitter(quittable: [herdApp]))
        await model.start()
        XCTAssertTrue(model.canQuitBlockingHolder)
        XCTAssertEqual(model.setupActionTitle, "Try Again")
    }

    func testAHolderThatCannotBeQuitStillGetsTryAgainWhichRetries() async {
        let holder = PortHolder(port: 80, pid: 9, command: "httpd", ownedByCurrentUser: false)
        let client = FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) }
        let services = FakeServices()
        services.startError = DaemonLaunchError.portsBlocked([holder])
        let model = AppModel(client: client, services: services, quitter: FakeQuitter())
        await model.start()
        XCTAssertFalse(model.canQuitBlockingHolder)
        XCTAssertEqual(model.blockedExplanation, Messages.portsBlocked([holder]))
        XCTAssertEqual(model.setupActionTitle, "Try Again")

        // The owner stopped httpd; Try Again finishes setup.
        services.startError = nil
        client.handler = { _ in .ok(sampleStatus()) }
        await model.finishSetup()
        XCTAssertEqual(services.startCalls, 2)
        XCTAssertNil(model.setupActionTitle)
        XCTAssertEqual(model.statusLine, "Running")
    }

    func testSetupNeededOffersFinishSetupAndRunningOffersNothing() async {
        let client = FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) }
        let model = AppModel(client: client)
        await model.refresh()
        XCTAssertEqual(model.setupActionTitle, "Finish Setup\u{2026}")
        client.handler = { _ in .ok(sampleStatus()) }
        await model.refresh()
        XCTAssertNil(model.setupActionTitle)
    }

    func testARefreshShowingTheHelperInstalledClearsStaleHeldPorts() async {
        let client = FakeClient { _ in .ok(sampleStatus(portHelperInstalled: false)) }
        let services = FakeServices()
        services.startError = DaemonLaunchError.portsBlocked(herdHolders())
        let model = AppModel(client: client, services: services, quitter: FakeQuitter())
        await model.start()
        XCTAssertEqual(model.setupBlockedBy, herdHolders())
        // Setup was finished elsewhere (paddock start in Terminal).
        client.handler = { _ in .ok(sampleStatus()) }
        await model.refresh()
        XCTAssertEqual(model.setupBlockedBy, [])
        XCTAssertEqual(model.statusLine, "Running")
        XCTAssertNil(model.blockedExplanation)
    }

    func testSudoIsReportedAsOneLine() async {
        let services = FakeServices()
        services.startError = DaemonLaunchError.runningAsRoot
        let model = AppModel(client: FakeClient { _ in throw ClientError.daemonNotRunning }, services: services)
        await model.start()
        XCTAssertEqual(model.lastError, Messages.runningAsRoot)
    }

    // MARK: - Trusting the certificate again

    func testTrustCertificateIsOfferedOnlyWhileSecuredSitesNeedTrust() async {
        let client = FakeClient { _ in .ok(sampleStatus(needsTrust: true)) }
        let model = AppModel(client: client)
        XCTAssertNil(model.trustActionTitle, "nothing to offer before the first status")
        await model.refresh()
        XCTAssertEqual(model.trustActionTitle, "Trust Certificate\u{2026}")
        XCTAssertEqual(AppModel.trustCertificateTitle, "Trust Certificate\u{2026}")

        // The action sends the existing `trust` request; once trusted, it is no longer offered.
        client.handler = { _ in .ok(sampleStatus(needsTrust: false)) }
        await model.trustCertificate()
        XCTAssertEqual(client.requests.filter { $0 == .trust }.count, 1)
        XCTAssertNil(model.trustActionTitle)
        XCTAssertNil(model.trustNotice)
    }

    func testTrustCertificateDeclinedShowsTheDaemonsSentence() async {
        let client = FakeClient { r in
            r == .trust ? .error(code: ErrorCode.needsTrust, message: Messages.stillNotTrusted)
                        : .ok(sampleStatus(needsTrust: true))
        }
        let model = AppModel(client: client)
        await model.refresh()
        await model.trustCertificate()
        XCTAssertEqual(model.trustNotice, Messages.stillNotTrusted)
        XCTAssertEqual(model.trustActionTitle, "Trust Certificate\u{2026}")
    }

    func testTrustCertificateIsAlsoOfferedToCleanUpAnOlderTrustedCertificate() async {
        let client = FakeClient { _ in .ok(sampleStatus(hasReplacedRootsToClean: true)) }
        let model = AppModel(client: client)
        await model.refresh()
        XCTAssertEqual(model.trustActionTitle, "Trust Certificate\u{2026}")
        client.handler = { _ in .ok(sampleStatus()) }
        await model.trustCertificate()
        XCTAssertEqual(client.requests.filter { $0 == .trust }.count, 1)
        XCTAssertNil(model.trustActionTitle)
    }

    // MARK: - A development build on the real system

    /// Every action that would change the system or the installed Paddock is refused with the one
    /// sentence, before anything is started, stopped, written or sent; status still shows.
    func testADevelopmentBuildRefusesEverySystemChangeButStillShowsStatus() async {
        let client = FakeClient { _ in .ok(sampleStatus(needsTrust: true)) }
        let services = FakeServices()
        services.refusal = DaemonLaunchError.developmentBuild
        let model = AppModel(client: client, services: services)
        await model.refresh()
        XCTAssertNotNil(model.status, "status is read-only and still works")

        let actions: [(String, () async -> Void)] = [
            ("start", { await model.start() }),
            ("finish setup", { await model.finishSetup() }),
            ("stop", { await model.stop() }),
            ("start at login", { await model.setStartsAtLogin(true) }),
            ("stop at login", { await model.setStartsAtLogin(false) }),
            ("restore", { await model.restorePreviousSetup() }),
            ("add to Terminal", { await model.addToTerminal() }),
            ("trust certificate", { await model.trustCertificate() }),
            ("secure", { await model.perform(.secure(site: "blog")) }),
            ("restart", { await model.perform(.restart) }),
        ]
        for (name, action) in actions {
            model.lastError = nil
            await action()
            XCTAssertEqual(model.lastError, Messages.developmentBuild, name)
        }
        XCTAssertEqual(services.startCalls, 0)
        XCTAssertEqual(services.stopCalls, 0)
        XCTAssertEqual(services.loginSettings, [])
        XCTAssertEqual(services.restoreCalls, 0)
        XCTAssertEqual(services.configureCalls, 0)
        XCTAssertTrue(client.requests.allSatisfy { $0 == .status }, "only status was ever sent: \(client.requests)")

        // First launch with no daemon answering: the start is refused too.
        client.handler = { _ in throw ClientError.daemonNotRunning }
        model.lastError = nil
        await model.launch()
        XCTAssertEqual(model.lastError, Messages.developmentBuild)
        XCTAssertEqual(services.startCalls, 0)
    }

    // MARK: - Another copy

    func testADaemonFromAnotherCopySaysWhereItRunsFrom() async {
        var elsewhere = sampleStatus()
        elsewhere.executablePath = "/Volumes/Work/Paddock.app/Contents/MacOS/paddockd"
        let other = elsewhere
        let client = FakeClient { _ in .ok(other) }
        let model = AppModel(client: client, ownExecutable: "/Applications/Paddock.app/Contents/MacOS/PaddockApp")
        await model.refresh()
        XCTAssertEqual(model.anotherCopyLocation, "/Volumes/Work/Paddock.app")
        XCTAssertEqual(model.statusLine, "Running from another copy at /Volumes/Work/Paddock.app")

        var own = sampleStatus()
        own.executablePath = "/Applications/Paddock.app/Contents/MacOS/paddockd"
        let mine = own
        client.handler = { _ in .ok(mine) }
        await model.refresh()
        XCTAssertNil(model.anotherCopyLocation, "its own app's daemon")
        XCTAssertEqual(model.statusLine, "Running")
    }
}

// MARK: - Services

/// What the model put on the pasteboard and asked the system to open.
@MainActor
private final class Outside {
    var copied: [String] = []
    var opened: [URL] = []
}

private func service(_ id: String, name: String, kind: String = "mail", state: ServiceState = .running,
                     ports: [String: Int] = ["main": 1025], openURL: String? = nil, notice: String? = nil,
                     notes: [String]? = nil, env: [String] = ["MAIL_PORT=1025"], secrets: [String]? = nil) -> ServiceStatus {
    ServiceStatus(id: id, name: name, kind: kind, version: "1.0", displayName: name, state: state, ports: ports,
                  env: env, openURL: openURL, dataPath: "/h/services/\(id)/data", autostart: true,
                  mainPort: ports["main"], notice: notice, notes: notes, secretEnvNames: secrets)
}

private func statusWith(services: [ServiceStatus] = [], sites: [Site]? = nil) -> EngineStatus {
    var status = sampleStatus(sites: sites)
    status.services = services
    return status
}

private let mail = service("mail", name: "Mail", ports: ["smtp": 1025, "http": 8025], openURL: "http://127.0.0.1:8025")
private let postgres = service("postgres-18", name: "PostgreSQL 18", kind: "postgres", state: .stopped,
                               ports: ["main": 5432], env: ["DB_CONNECTION=pgsql", "DB_PORT=5432"])
private let meili = service("meilisearch-1-57", name: "Meilisearch 1.57", kind: "meilisearch",
                            state: .portInUse(holder: "nc (pid 7)"), ports: ["main": 7700],
                            openURL: "http://127.0.0.1:7700",
                            notes: ["Search indexes are tied to Meilisearch 1.57; export a dump before changing version."],
                            env: ["SCOUT_DRIVER=meilisearch", "MEILISEARCH_HOST=http://127.0.0.1:7700"],
                            secrets: ["MEILISEARCH_KEY"])

private let secretKey = "Zm9vYmFyLXNlY3JldC1rZXktdGhhdC1tdXN0LW5ldmVyLWxlYWs"

extension AppModelTests {
    private func servicesModel(_ handler: @escaping @Sendable (Request) throws -> Response,
                               refusal: Error? = nil) -> (AppModel, FakeClient, Outside) {
        let client = FakeClient(handler)
        let outside = Outside()
        let services = FakeServices()
        services.refusal = refusal
        let model = AppModel(client: client, services: services,
                             copyText: { outside.copied.append($0) }, open: { outside.opened.append($0) })
        return (model, client, outside)
    }

    func testServiceRowsSayWhatEachServiceIsDoingInTheCLIsWords() async {
        let (model, _, _) = servicesModel { _ in .ok(statusWith(services: [mail, postgres, meili])) }
        XCTAssertEqual(model.serviceRows, [], "nothing before the first status")
        await model.refresh()
        let rows = model.serviceRows
        XCTAssertEqual(rows.map(\.id), ["mail", "postgres-18", "meilisearch-1-57"])
        XCTAssertEqual(rows.map(\.name), ["Mail", "PostgreSQL 18", "Meilisearch 1.57"])
        XCTAssertEqual(rows.map(\.stateText), ["running", "stopped", "port in use by nc (pid 7)"])
        XCTAssertEqual(rows.map(\.portText), ["1025 (smtp), 8025 (http)", "5432 (main)", "7700 (main)"])
        XCTAssertEqual(rows.map(\.notes), [[], [], ["Search indexes are tied to Meilisearch 1.57; export a dump before changing version."]])
        XCTAssertEqual(rows.map(\.canStart), [false, true, true])
        XCTAssertEqual(rows.map(\.canStop), [true, false, false])
        XCTAssertEqual(rows.map(\.canOpen), [true, false, false], "a page opens only while the service runs")
        XCTAssertEqual(rows.map(\.canCreateDatabase), [false, false, false], "PostgreSQL only, and only while it runs")
        XCTAssertEqual(rows[2].envText, "SCOUT_DRIVER=meilisearch\nMEILISEARCH_HOST=http://127.0.0.1:7700\n"
                       + "# MEILISEARCH_KEY: run \"paddock service env meilisearch-1-57\"")

        var running = postgres
        running.state = .running
        let noticed = service("mail", name: "Mail", notice: "Found existing data for Mail; using it.")
        let fresh = statusWith(services: [noticed, running])
        model.status = fresh
        XCTAssertEqual(model.serviceRows.map(\.canCreateDatabase), [false, true])
        XCTAssertEqual(model.serviceRows.first?.notes, ["Found existing data for Mail; using it."])
    }

    func testStartStopAndRestartSendTheServiceRequests() async {
        let (model, client, _) = servicesModel { _ in .ok(statusWith(services: [mail])) }
        await model.startService("mail")
        await model.stopService("mail")
        await model.restartService("mail")
        XCTAssertEqual(client.requests.filter { $0 != .status },
                       [.serviceStart(name: "mail"), .serviceStop(name: "mail"), .serviceRestart(name: "mail")])
    }

    func testRemoveKeepsTheDataAndSaysWhereItIsInTheCLIsWords() async {
        let (model, client, _) = servicesModel { request in
            if case .serviceRemove = request { return .removed(dataPath: "/h/services/mail/data", status: statusWith()) }
            return .ok(statusWith(services: [mail]))
        }
        await model.refresh()
        await model.removeService("mail", deleteData: false)
        XCTAssertEqual(client.requests.filter { $0 != .status }, [.serviceRemove(name: "mail", deleteData: false)])
        XCTAssertEqual(model.serviceNotice, "Removed Mail. Its data is still at /h/services/mail/data.")
        XCTAssertNil(model.lastError)
    }

    /// Deleting data needs the model's own confirmation flag, set by asking first: a view can't skip it.
    func testDeletingDataNeedsOneConfirmationNamingTheService() async {
        let (model, client, _) = servicesModel { request in
            if case .serviceRemove = request { return .removed(dataPath: "/h/services/mail/data", status: statusWith()) }
            return .ok(statusWith(services: [mail, postgres]))
        }
        await model.refresh()
        await model.removeService("mail", deleteData: true)
        XCTAssertEqual(client.requests.filter { $0 != .status }, [], "never without asking first")
        XCTAssertNil(model.deleteDataQuestion)

        model.askToRemoveAndDeleteData("mail")
        XCTAssertEqual(model.deleteDataQuestion, "Remove Mail and delete its data? This can't be undone.")
        await model.removeService("postgres-18", deleteData: true)
        XCTAssertEqual(client.requests.filter { $0 != .status }, [], "the confirmation is for that service only")
        model.cancelRemoveAndDeleteData()
        XCTAssertNil(model.deleteDataQuestion)
        await model.removeService("mail", deleteData: true)
        XCTAssertEqual(client.requests.filter { $0 != .status }, [], "a cancelled question confirms nothing")

        model.askToRemoveAndDeleteData("mail")
        await model.removeService("mail", deleteData: true)
        XCTAssertEqual(client.requests.filter { $0 != .status }, [.serviceRemove(name: "mail", deleteData: true)])
        XCTAssertEqual(model.serviceNotice, "Removed Mail and deleted its data.")
        XCTAssertNil(model.deleteDataQuestion, "used once")
        await model.removeService("mail", deleteData: true)
        XCTAssertEqual(client.requests.filter { $0 != .status }.count, 1, "and only once")
    }

    /// Copy .env fetches the full lines at the click and hands them to the pasteboard; the secret is never kept
    /// in the model's state or put in a message.
    func testCopyEnvFetchesTheSecretAtTheClickAndKeepsItNowhere() async throws {
        let full = ["SCOUT_DRIVER=meilisearch", "MEILISEARCH_HOST=http://127.0.0.1:7700", "MEILISEARCH_KEY=\(secretKey)"]
        let (model, client, outside) = servicesModel { request in
            if case .serviceEnv = request { return .envLines(full) }
            return .ok(statusWith(services: [meili]))
        }
        await model.refresh()
        await model.copyEnv("meilisearch-1-57")
        XCTAssertEqual(client.requests.filter { $0 != .status }, [.serviceEnv(id: "meilisearch-1-57")])
        XCTAssertEqual(outside.copied, [full.joined(separator: "\n") + "\n"])
        XCTAssertEqual(model.serviceNotice, "Copied the .env lines of Meilisearch 1.57.")
        let published = [String(describing: model.status), String(describing: model.serviceRows),
                         model.serviceNotice ?? "", model.lastError ?? "", String(describing: model.catalog),
                         String(describing: model.busy)].joined()
        XCTAssertFalse(published.contains(secretKey), "the secret is in no published state")

        // An error never carries the lines; nothing is copied.
        client.handler = { request in
            if case .serviceEnv = request { return .error(code: ErrorCode.unknownService, message: "No service named \"x\".") }
            return .ok(statusWith(services: [meili]))
        }
        await model.copyEnv("x")
        XCTAssertEqual(model.lastError, "No service named \"x\".")
        XCTAssertEqual(outside.copied.count, 1)
    }

    func testCopyEnvFromADevelopmentBuildIsRefusedWithItsSentence() async {
        let (model, client, outside) = servicesModel({ _ in .ok(statusWith(services: [meili])) },
                                                     refusal: DaemonLaunchError.developmentBuild)
        await model.copyEnv("meilisearch-1-57")
        XCTAssertEqual(model.lastError, Messages.developmentBuild)
        XCTAssertEqual(outside.copied, [])
        XCTAssertFalse(client.requests.contains(.serviceEnv(id: "meilisearch-1-57")))

        // And the client's own refusal reads the same.
        let (other, otherClient, _) = servicesModel { request in
            if case .serviceEnv = request { throw ClientError.developmentBuild }
            return .ok(statusWith(services: [meili]))
        }
        await other.copyEnv("meilisearch-1-57")
        XCTAssertEqual(other.lastError, Messages.developmentBuild)
        XCTAssertTrue(otherClient.requests.contains(.serviceEnv(id: "meilisearch-1-57")))
    }

    func testOpenOpensTheServicesPageOnlyWhenItHasOne() async {
        let (model, _, outside) = servicesModel { _ in .ok(statusWith(services: [mail, postgres])) }
        await model.refresh()
        model.openService("mail")
        model.openService("postgres-18")
        XCTAssertEqual(outside.opened, [URL(string: "http://127.0.0.1:8025")!])
    }

    func testCreateDatabaseChecksTheNameAsTheDaemonDoesThenSendsTheRequest() async {
        var running = postgres
        running.state = .running
        let current = statusWith(services: [running])
        let (model, client, _) = servicesModel { request in
            if case .serviceCreateDatabase(_, let database) = request {
                return .databaseCreated(database: database, alreadyExisted: database == "shop", status: current)
            }
            return .ok(current)
        }
        await model.refresh()
        XCTAssertTrue(AppModel.isValidDatabaseName("tmarket_2"))
        XCTAssertFalse(AppModel.isValidDatabaseName("my-shop"))
        XCTAssertFalse(AppModel.isValidDatabaseName(""))
        XCTAssertFalse(AppModel.isValidDatabaseName(String(repeating: "a", count: 64)))

        await model.createDatabase(in: "postgres-18", named: "my-shop")
        XCTAssertEqual(model.lastError, "Database names can use letters, numbers and underscores.")
        XCTAssertEqual(client.requests.filter { $0 != .status }, [], "an invalid name is never sent")

        await model.createDatabase(in: "postgres-18", named: "tmarket")
        XCTAssertEqual(client.requests.filter { $0 != .status },
                       [.serviceCreateDatabase(name: "postgres-18", database: "tmarket")])
        XCTAssertEqual(model.serviceNotice, "Created database tmarket in PostgreSQL 18.")
        XCTAssertNil(model.lastError)
        await model.createDatabase(in: "postgres-18", named: "shop")
        XCTAssertEqual(model.serviceNotice, "shop already exists in PostgreSQL 18.")
    }

    func testCatalogRowsListEverySeriesWithItsLicence() async {
        let entries = [
            CatalogEntry(kind: "mail", displayName: "Mail", licence: "MIT", versions: ["1.34.0"], downloadBytes: 11_000_000,
                         series: [CatalogSeries(series: "1", version: "1.34.0", downloadBytes: 11_000_000, needsDownload: true)]),
            CatalogEntry(kind: "postgres", displayName: "PostgreSQL", licence: "PostgreSQL", versions: ["18.7.0", "17.12.0"],
                         downloadBytes: nil,
                         series: [CatalogSeries(series: "18", version: "18.7.0", downloadBytes: nil, needsDownload: false),
                                  CatalogSeries(series: "17", version: "17.12.0", downloadBytes: nil, needsDownload: true)]),
        ]
        let (model, client, _) = servicesModel { request in
            if case .serviceCatalog = request { return .catalog(entries) }
            return .ok(statusWith())
        }
        XCTAssertEqual(model.catalog, [])
        await model.loadCatalog()
        XCTAssertEqual(client.requests, [.serviceCatalog], "read-only, and no refresh needed")
        XCTAssertEqual(model.catalog.map(\.title), ["Mail 1.34.0", "PostgreSQL 18.7.0", "PostgreSQL 17.12.0"])
        XCTAssertEqual(model.catalog.map(\.licence), ["MIT", "PostgreSQL", "PostgreSQL"])
        XCTAssertEqual(model.catalog.map(\.kind), ["mail", "postgres", "postgres"])
        XCTAssertEqual(model.catalog.map(\.version), ["1", "18", "17"])
        XCTAssertEqual(model.catalog.map(\.isAdding), [false, false, false])
    }

    /// An add downloads and may take minutes: while it is in flight its entry says so, status polling goes on,
    /// and other actions still work.
    func testAnAddInFlightLeavesPollingAndOtherActionsAlive() async throws {
        let release = DispatchSemaphore(value: 0)
        let after = statusWith(services: [mail, postgres])
        let polled = Locked<EngineStatus>(statusWith(services: [mail]))
        let entries = [CatalogEntry(kind: "postgres", displayName: "PostgreSQL", licence: "PostgreSQL",
                                    versions: ["18.7.0"], downloadBytes: nil,
                                    series: [CatalogSeries(series: "18", version: "18.7.0", downloadBytes: nil,
                                                           needsDownload: true)])]
        let (model, client, _) = servicesModel { request in
            switch request {
            case .serviceAdd:
                release.wait()
                return .ok(after)
            case .serviceCatalog:
                return .catalog(entries)
            default:
                return .ok(polled.value)
            }
        }
        await model.loadCatalog()
        let add = Task { await model.addService(kind: "postgres", version: "18") }
        let deadline = Date().addingTimeInterval(5)
        while !model.isAdding(kind: "postgres", version: "18") && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(model.isAdding(kind: "postgres", version: "18"))
        XCTAssertEqual(model.catalog.map(\.isAdding), [true])

        polled.withValue { $0.services[0].state = .stopped }
        await model.refresh()
        XCTAssertEqual(model.serviceRows.map(\.stateText), ["stopped"], "polling goes on during the add")
        await model.startService("mail")
        XCTAssertTrue(client.requests.contains(.serviceStart(name: "mail")), "other actions still work")
        XCTAssertTrue(model.isAdding(kind: "postgres", version: "18"))

        release.signal()
        await add.value
        XCTAssertFalse(model.isAdding(kind: "postgres", version: "18"))
        XCTAssertTrue(client.requests.contains(.serviceAdd(kind: "postgres", version: "18")))
        let addTimeout = zip(client.requests, client.timeouts).first { $0.0 == .serviceAdd(kind: "postgres", version: "18") }?.1
        XCTAssertEqual(addTimeout, 3600, "as long as the CLI waits for a download")
    }

    func testAFailedAddGoesToTheErrorLine() async {
        let (model, _, _) = servicesModel { request in
            if case .serviceAdd = request {
                return .error(code: ErrorCode.serviceUnavailable, message: "PostgreSQL 18 needs macOS 15 or later.")
            }
            return .ok(statusWith())
        }
        await model.addService(kind: "postgres", version: "18")
        XCTAssertEqual(model.lastError, "PostgreSQL 18 needs macOS 15 or later.")
    }
}
