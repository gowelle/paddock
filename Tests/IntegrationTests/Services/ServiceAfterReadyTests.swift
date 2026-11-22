import Darwin
import XCTest
@testable import PaddockCore

/// A recipe's `afterReady` steps, with the fake service: run once against the service that has just become
/// ready, never again for that instance, and a failing step leaves the service stopped and to be tried again.
final class ServiceAfterReadyTests: XCTestCase {
    private var home: ServiceHome!
    private var managers: [ServiceManager] = []

    override func setUpWithError() throws {
        try FakeService.requireBuilt()
        home = try ServiceHome()
    }

    override func tearDown() {
        for manager in managers { manager.stopAll() }
        managers = []
        home?.cleanUp()
    }

    private func makeManager(_ recipe: ServiceRecipe) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: [recipe]),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.1),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        managers.append(manager)
        return manager
    }

    private var program: String { "{bin}/\(FakeService.installedName)" }

    private var marker: URL {
        home.paths.serviceConfig("fake").appendingPathComponent(ServiceManager.afterReadyMarker)
    }

    private func made(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: home.paths.serviceData("fake").appendingPathComponent("made-\(name)").path)
    }

    /// The step runs after the service is ready (it finds the service's own files), in the instance's folder,
    /// and only on the first start: the fake's action fails when run twice, so a second run would stop the service.
    func testAStepRunsOnceAfterTheFirstStartThatBecameReady() async throws {
        let step = RecipeCommand(executable: program, arguments: ["action", "{data}", "bucket"])
        let manager = makeManager(FakeService.recipe(afterReady: [step]))
        let added = try await manager.add(kind: "fake", version: nil)
        XCTAssertEqual(manager.statuses().first?.state, .running)
        XCTAssertTrue(made("bucket"), "the step ran")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "and is recorded as run")
        // The service was already serving when the step ran: its arguments file was there before the step's.
        XCTAssertFalse(FakeService.arguments(paths: home.paths, id: added.id).isEmpty)
        let cwd = try String(contentsOf: home.paths.serviceData("fake").appendingPathComponent("action-cwd"), encoding: .utf8)
        XCTAssertEqual(ServiceManager.realPath(cwd.trimmingCharacters(in: .whitespacesAndNewlines)),
                       ServiceManager.realPath(home.paths.serviceHome("fake").path))

        manager.stop("fake")
        try manager.start("fake")
        XCTAssertEqual(manager.statuses().first?.state, .running, "not run a second time")
        XCTAssertEqual(manager.logTail("fake").components(separatedBy: "already exists").count - 1, 0)

        // A new manager (a daemon restart) doesn't run it again either.
        manager.stopAll()
        let next = makeManager(FakeService.recipe(afterReady: [step]))
        try next.start("fake")
        XCTAssertEqual(next.statuses().first?.state, .running)
    }

    /// A step that fails: the add fails with what the step said, the service is not left running, nothing is
    /// recorded as done.
    func testAFailingStepStopsTheServiceAndIsNotRecorded() async throws {
        let step = RecipeCommand(executable: program, arguments: ["init", "{data}", "--fail", "no bucket for you"])
        let manager = makeManager(FakeService.recipe(afterReady: [step]))
        do {
            _ = try await manager.add(kind: "fake", version: nil)
            XCTFail("the add should fail")
        } catch let error as ServiceError {
            guard case .initialiseFailed(_, let output) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(output.contains("no bucket for you"), output)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(manager.processes[ServiceManager.processName("fake")].flatMap(TestSupport.pid(from:)),
                     "the service is not left running")
    }

    /// A recipe with no such steps writes no marker.
    func testNoStepsNoMarker() async throws {
        let manager = makeManager(FakeService.recipe())
        _ = try await manager.add(kind: "fake", version: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
