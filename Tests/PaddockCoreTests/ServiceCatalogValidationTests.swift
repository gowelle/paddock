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

    /// Decoding a catalog validates it, so a bad bundled, hosted or development catalog never loads.
    func testDecodingValidates() throws {
        let bad = ServiceCatalog(recipes: [valid(stopSignal: "KILL")])
        XCTAssertThrowsError(try JSONDecoder().decode(ServiceCatalog.self, from: JSONEncoder().encode(bad)))
    }
}
