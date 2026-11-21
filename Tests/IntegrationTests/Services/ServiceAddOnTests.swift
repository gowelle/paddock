import CryptoKit
import Darwin
import XCTest
@testable import PaddockCore

/// A recipe gaining a later asset (PostGIS over PostgreSQL) and notes, with the fake service on free high
/// ports: an instance installed before is completed from its own files at its next start (or by update),
/// its data untouched, and the catalog's description of the installed build is the one used.
final class ServiceAddOnTests: XCTestCase {
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

    private func makeManager(_ recipes: [ServiceRecipe]) -> ServiceManager {
        let manager = ServiceManager(paths: home.paths, catalog: ServiceCatalog(recipes: recipes),
                                     store: StateStore(paths: home.paths), supervisor: Supervisor(backoffScale: 0.05),
                                     portCheck: .withoutProbes, portBase: home.portBase)
        managers.append(manager)
        return manager
    }

    /// `share/addon.txt` in a local tar.gz.
    private func addOn() throws -> RecipeAsset {
        let source = home.root.appendingPathComponent("addon-src/share", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("add-on\n".utf8).write(to: source.appendingPathComponent("addon.txt"))
        let archive = home.root.appendingPathComponent("addon.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", source.deletingLastPathComponent().path, "share"]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        try tar.run()
        tar.waitUntilExit()
        let sha = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        return RecipeAsset(artifact: Artifact(url: archive, sha256: sha), archive: "tar.gz")
    }

    private func withAddOn(_ notes: [String] = ["Includes the add-on."]) throws -> ServiceRecipe {
        FakeService.recipe(assets: [FakeService.asset, try addOn()], notes: notes)
    }

    private var marker: URL { home.paths.serviceData("fake").appendingPathComponent("kept") }
    private var addOnFile: URL {
        home.paths.serviceBin(kind: "fake", version: "1.0").appendingPathComponent("share/addon.txt")
    }

    func testAnInstanceGainsALaterAssetAtItsNextStartWithItsDataKept() async throws {
        let first = makeManager([FakeService.recipe()])
        _ = try await first.add(kind: "fake", version: nil)
        try Data("data".utf8).write(to: marker)
        first.stopAll()

        let recipe = try withAddOn()
        let second = makeManager([recipe])
        try second.start("fake")
        let status = try XCTUnwrap(second.statuses().first)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.version, "1.0")
        XCTAssertEqual(status.notes, ["Includes the add-on."])
        XCTAssertEqual(try String(contentsOf: addOnFile, encoding: .utf8), "add-on\n")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "data", "its data is untouched")
        XCTAssertEqual(second.installer.installedRecipe(kind: "fake", version: "1.0"), recipe)
        XCTAssertEqual(FakeService.arguments(paths: home.paths, id: "fake").first, FakeService.installed(paths: home.paths))
    }

    func testUpdateCompletesAnInstallMissingALaterAsset() async throws {
        let first = makeManager([FakeService.recipe()])
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        let recipe = try withAddOn()
        let second = makeManager([recipe])
        let updated = try await second.update("fake")
        XCTAssertEqual(updated.version, "1.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: addOnFile.path))
        XCTAssertTrue(second.installer.isInstalled(recipe))
        XCTAssertEqual(second.statuses().first?.state, .running)
    }

    /// The same downloads described better (new lock files, readiness, notes) take effect without a reinstall:
    /// the catalog's recipe of the installed build is used, and stored.
    func testTheCatalogsRecipeOfTheInstalledBuildIsUsed() async throws {
        let first = makeManager([FakeService.recipe()])
        _ = try await first.add(kind: "fake", version: nil)
        first.stopAll()
        let described = FakeService.recipe(lockFiles: ["{data}/fake.pid"], notes: ["Described better."])
        let second = makeManager([described])
        try second.start("fake")
        XCTAssertEqual(second.statuses().first?.notes, ["Described better."])
        XCTAssertEqual(second.installer.installedRecipe(kind: "fake", version: "1.0"), described)
    }
}
