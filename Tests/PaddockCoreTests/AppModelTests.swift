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
    func configureShell() throws { isShellConfigured = true }
    func parkedFolders() -> [String] { parked }
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
                          needsTrust: Bool = false) -> EngineStatus {
    EngineStatus(running: running, blockedBy: blockedBy,
                 sites: sites ?? [Site(name: "blog", path: "/p/blog", kind: .parked, secured: true,
                                       php: v85, pinned: false)],
                 installedPHP: [v84, v85], defaultPHP: v85, processes: [:],
                 resolverInstalled: true, trustEnabled: true, dnsRunning: true,
                 portHelperInstalled: portHelperInstalled, needsTrust: needsTrust)
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
                                executablePath: "/opt/local/sbin/nginx", serverHeader: "nginx/1.30.6",
                                serviceName: "MacPorts nginx", stopCommand: "sudo port unload nginx")
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
}
