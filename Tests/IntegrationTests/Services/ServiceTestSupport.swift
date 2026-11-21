import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import PaddockCore

/// The stand-in service (`Tests/FakeService`, built as `paddock-fake-service`) and recipes that run it.
enum FakeService {
    static var binary: URL {
        Bundle(for: ServiceHome.self).bundleURL.deletingLastPathComponent().appendingPathComponent("paddock-fake-service")
    }

    static func requireBuilt() throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("paddock-fake-service not built at \(binary.path)")
            throw XCTSkip("paddock-fake-service missing")
        }
    }

    /// The fake's preferred port; tests move it into a free high range with `ServiceHome.portBase`.
    static let preferredPort = 1100
    static let installedName = "paddock-fake-service"

    /// The built helper as a verified download: a `binary` asset from a `file://` URL, installed into
    /// `{bin}` like any service's program.
    static var asset: RecipeAsset {
        RecipeAsset(artifact: Artifact(url: binary, sha256: binarySHA256, size: binarySize), archive: "binary",
                    installAs: installedName)
    }

    private static let binarySize = (try? FileManager.default.attributesOfItem(atPath: binary.path)[.size] as? Int) ?? nil

    private static let binarySHA256: String = {
        let data = (try? Data(contentsOf: binary)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()

    /// A recipe whose service is the fake: it listens on 127.0.0.1 on every port and on `{socket}`, and
    /// records its arguments in `{data}/args` and its environment in `{data}/env`.
    static func recipe(kind: String = "fake", version: String = "1.0", series: String? = nil, seriesInID: Bool = false,
                       displayName: String = "Fake",
                       ports: [RecipePort] = [RecipePort(name: "main", preferred: preferredPort)],
                       extraArguments: [String] = [], initialiseFailure: String? = nil,
                       initialiseArguments: [String] = [], initialiseTimeoutSeconds: Int? = nil,
                       assets: [RecipeAsset]? = nil, socket: String? = "{run}/fake.sock",
                       ready: Readiness = .tcp(port: "{port.main}"), stopSignal: String = "TERM",
                       configFiles: [RecipeFile] = [], readyTimeoutSeconds: Int? = nil,
                       actions: [String: RecipeAction] = [:], lockFiles: [String] = [],
                       stopGraceSeconds: Int = 5, notes: [String] = []) -> ServiceRecipe {
        var arguments = ["serve", "{data}"]
        for port in ports { arguments += ["--port", "{port.\(port.name)}"] }
        arguments += ["--socket", "{socket}", "--name", "{name}"] + extraArguments
        let initialise = ["init", "{data}"] + (initialiseFailure.map { ["--fail", $0] } ?? []) + initialiseArguments
        let program = "{bin}/\(installedName)"
        return ServiceRecipe(
            kind: kind, displayName: displayName, version: version, series: series, seriesInID: seriesInID,
            licence: "MIT", assets: assets ?? [asset],
            initialise: [RecipeCommand(executable: program, arguments: initialise.map(RecipeArgument.plain))],
            start: RecipeCommand(executable: program, arguments: arguments.map(RecipeArgument.plain)),
            ready: ready, stopSignal: stopSignal, stopGraceSeconds: stopGraceSeconds, ports: ports, socket: socket,
            env: ["FAKE_HOST=127.0.0.1", "FAKE_PORT={port.main}", "FAKE_SOCKET={socket}"],
            openURL: "http://127.0.0.1:{port.main}", configFiles: configFiles,
            readyTimeoutSeconds: readyTimeoutSeconds, initialiseTimeoutSeconds: initialiseTimeoutSeconds,
            actions: actions, lockFiles: lockFiles, notes: notes)
    }

    /// Like createdb: `action <data> <database>` makes `made-<database>` in the data folder, and says
    /// `"<database>" already exists` the second time.
    static let createDatabase = RecipeAction(
        command: RecipeCommand(executable: "{bin}/\(installedName)", arguments: ["action", "{data}", "{database}"]),
        parameters: [RecipeParameter(name: "database", pattern: "^[A-Za-z0-9_]{1,63}$")],
        alreadyDone: "\"{database}\" already exists")

    /// The installed program an instance of `version` runs.
    static func installed(paths: Paths, kind: String = "fake", version: String = "1.0") -> String {
        paths.serviceBin(kind: kind, version: version).appendingPathComponent(installedName).path
    }

    /// The environment the running fake recorded, as `NAME=value` lines.
    static func environment(paths: Paths, id: String) -> [String] {
        let text = (try? String(contentsOf: paths.serviceData(id).appendingPathComponent("env"), encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// The arguments the running fake recorded.
    static func arguments(paths: Paths, id: String) -> [String] {
        let text = (try? String(contentsOf: paths.serviceData(id).appendingPathComponent("args"), encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n").dropLast()
    }
}

/// A throwaway home for service tests, directly under /tmp (Unix socket paths are short), with a port
/// base that moves every preferred port into a free high range.
final class ServiceHome {
    let root: URL
    let paths: Paths
    /// `FakeService.preferredPort + portBase` (`fakePort`) was free when the home was made.
    let portBase: Int
    var fakePort: Int { portBase + FakeService.preferredPort }

    init(longFolder: Bool = false) throws {
        var root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pdk-\(TestSupport.token())", isDirectory: true)
        if longFolder {
            root = root.appendingPathComponent(String(repeating: "long-folder-name-", count: 5), isDirectory: true)
        }
        self.root = root
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureDirectories()
        var base = 0
        repeat { base = TestSupport.freeTCPPort() - FakeService.preferredPort } while !(1024...55000).contains(base)
        portBase = base
    }

    func cleanUp() {
        // The long variant lives one folder down: remove the whole /tmp/pdk-… folder.
        var top = root
        while top.deletingLastPathComponent().path != "/tmp" { top = top.deletingLastPathComponent() }
        try? FileManager.default.removeItem(at: top)
    }
}

/// Where downloaded service archives are kept between test runs (`Vendor/services/`, git-ignored).
enum ServiceDownloadCache {
    static let directory = TestSupport.repoVendor.appendingPathComponent("services", isDirectory: true)

    /// The artifact as a `file://` URL in the cache, downloading it there (verified) first if it isn't
    /// cached; skips the test when it is neither cached nor downloadable.
    static func local(_ artifact: Artifact) async throws -> Artifact {
        // Paddock's own builds (the PostGIS add-on) come from Vendor/builds/, as in a development home.
        if artifact.url.scheme == BuildSource.scheme {
            guard BuildSource.resolve(artifact.url) != nil else {
                throw XCTSkip("\(BuildSource.fileName(artifact.url) ?? "?") is not in Vendor/builds/; build it with "
                              + "Scripts/build-postgis.sh (or copy the archive there)")
            }
            return artifact
        }
        let cached = directory.appendingPathComponent("\(artifact.sha256.lowercased())-\(artifact.url.lastPathComponent)")
        if !FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let file = try await ArtifactDownloader().fetch(artifact, into: directory, progress: nil)
                try FileManager.default.moveItem(at: file, to: cached)
            } catch {
                throw XCTSkip("\(artifact.url.lastPathComponent) is not in Vendor/services/ and could not be "
                              + "downloaded (\(error)); connect to the internet once to cache it")
            }
        }
        return Artifact(url: cached, sha256: artifact.sha256, size: artifact.size)
    }

    /// The recipe with every asset served from the cache.
    static func localRecipe(_ recipe: ServiceRecipe) async throws -> ServiceRecipe {
        var assets: [RecipeAsset] = []
        for asset in recipe.assets {
            assets.append(RecipeAsset(artifact: try await local(asset.artifact), archive: asset.archive,
                                      stripComponents: asset.stripComponents, installAs: asset.installAs))
        }
        return recipe.withAssets(assets)
    }
}

/// A listening TCP socket on 127.0.0.1:<port>, bound with SO_REUSEADDR so a port a test service just
/// left (its probe connections in TIME_WAIT) can be taken at once; the caller closes it.
func listenReusingAddress(port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EMFILE) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = TestSupport.socketAddress(port: port)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
    guard bound, Darwin.listen(fd, 4) == 0 else {
        close(fd)
        throw POSIXError(.EADDRINUSE)
    }
    return fd
}

/// For every recipe's integration test: the TCP listeners of a service's whole process group, read and judged
/// by the same code the manager uses at run time, failing on any that isn't on 127.0.0.1 or [::1]. Returns
/// the addresses.
@discardableResult
func assertListensOnThisMacOnly(processGroup: Int32, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
    let addresses = try ServiceManager.listeningAddresses(processGroup: processGroup, runner: SystemCommandRunner())
    XCTAssertFalse(addresses.isEmpty, "the service listens somewhere", file: file, line: line)
    for address in addresses {
        XCTAssertTrue(ServiceManager.isLoopback(address), "\(address) is not this Mac only", file: file, line: line)
    }
    return addresses
}

/// Polls until `condition` holds or `timeout` passes.
func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}
