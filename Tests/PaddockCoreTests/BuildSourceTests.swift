import XCTest
@testable import PaddockCore

final class BuildSourceTests: XCTestCase {
    private var scratch: URL!
    private var buildsDir: URL!
    private var resources: URL!
    private let file = "php-8.4.28-cli-macos-x86_64.tar.gz"

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-buildsource-\(UUID().uuidString)", isDirectory: true)
        buildsDir = scratch.appendingPathComponent("builds-override", isDirectory: true)
        resources = scratch.appendingPathComponent("Resources", isDirectory: true)
        for dir in [buildsDir!, resources.appendingPathComponent("builds", isDirectory: true)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var url: URL { URL(string: "paddock-builds://\(file)")! }

    private func put(_ directory: URL) throws -> URL {
        let target = directory.appendingPathComponent(file)
        try Data("archive".utf8).write(to: target)
        return target
    }

    private func environment(buildsDir: Bool = true) -> [String: String] {
        var env = ["PADDOCK_RESOURCES": resources.path]
        if buildsDir { env["PADDOCK_BUILDS_DIR"] = self.buildsDir.path }
        return env
    }

    func testBuildsDirectoryComesFirst() throws {
        let override = try put(buildsDir)
        _ = try put(resources.appendingPathComponent("builds"))
        XCTAssertEqual(BuildSource.resolve(url, environment: environment())?.path, override.path)
    }

    func testBundledResourcesWhenTheBuildsDirectoryLacksTheFile() throws {
        let bundled = try put(resources.appendingPathComponent("builds"))
        XCTAssertEqual(BuildSource.resolve(url, environment: environment())?.path, bundled.path)
        XCTAssertEqual(BuildSource.resolve(url, environment: environment(buildsDir: false))?.path, bundled.path)
    }

    func testResolvedURLIsAFileURL() throws {
        _ = try put(buildsDir)
        XCTAssertTrue(BuildSource.resolve(url, environment: environment())?.isFileURL ?? false)
    }

    func testNilWhenNowhere() {
        XCTAssertNil(BuildSource.resolve(url, environment: environment()))
        XCTAssertNil(BuildSource.resolve(url, environment: environment(buildsDir: false)))
    }

    func testOtherURLsPassThroughUnchanged() {
        let https = URL(string: "https://example.test/php-8.4.28-cli-macos-x86_64.tar.gz")!
        XCTAssertEqual(BuildSource.resolve(https, environment: environment()), https)
        let local = URL(fileURLWithPath: "/tmp/some.tar.gz")
        XCTAssertEqual(BuildSource.resolve(local, environment: environment()), local)
    }

    func testRefusesNamesThatLeaveTheDirectory() throws {
        // A file one level up from the builds directory must never be reachable through the scheme.
        try Data("x".utf8).write(to: scratch.appendingPathComponent("secret.tar.gz"))
        for text in ["paddock-builds://../secret.tar.gz", "paddock-builds://a/../../secret.tar.gz",
                     "paddock-builds://", "paddock-builds://.."] {
            guard let bad = URL(string: text) else { continue }
            XCTAssertNil(BuildSource.resolve(bad, environment: environment()), text)
        }
    }
}
