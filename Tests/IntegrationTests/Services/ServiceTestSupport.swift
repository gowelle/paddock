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

    /// A recipe whose service is the fake: it listens on 127.0.0.1 on every port (preferred ports are low;
    /// tests add a free high port base) and on `{socket}`, and records its arguments in `{data}/args`.
    static func recipe(kind: String = "fake", version: String = "1.0", displayName: String = "Fake",
                       ports: [RecipePort] = [RecipePort(name: "main", preferred: 100)],
                       extraArguments: [String] = [], initialiseFailure: String? = nil,
                       assets: [RecipeAsset] = [], socket: String? = "{run}/fake.sock",
                       ready: Readiness = .tcp(port: "{port.main}"), stopSignal: String = "TERM") -> ServiceRecipe {
        var arguments = ["serve", "{data}"]
        for port in ports { arguments += ["--port", "{port.\(port.name)}"] }
        arguments += ["--socket", "{socket}", "--name", "{name}"] + extraArguments
        return ServiceRecipe(
            kind: kind, displayName: displayName, version: version, licence: "MIT", assets: assets,
            initialise: [RecipeCommand(executable: binary.path,
                                       arguments: ["init", "{data}"] + (initialiseFailure.map { [$0] } ?? []))],
            start: RecipeCommand(executable: binary.path, arguments: arguments),
            ready: ready, stopSignal: stopSignal, stopGraceSeconds: 5, ports: ports, socket: socket,
            env: ["FAKE_HOST=127.0.0.1", "FAKE_PORT={port.main}", "FAKE_SOCKET={socket}"],
            openURL: "http://127.0.0.1:{port.main}")
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
    /// `preferred + portBase` is free (when checked) for the fake's preferred port 100.
    let portBase: Int

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
        repeat { base = TestSupport.freeTCPPort() - 100 } while !(1024...55000).contains(base)
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

/// Polls until `condition` holds or `timeout` passes.
func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}
