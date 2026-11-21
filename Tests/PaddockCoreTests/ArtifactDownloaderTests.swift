import CryptoKit
import XCTest
@testable import PaddockCore

/// Counts requests and fails every one: proves a fetch never touched the network.
final class NoNetworkURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

final class ArtifactDownloaderTests: XCTestCase {
    private var scratch: URL!
    private var into: URL!
    private var builds: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-artifact-\(UUID().uuidString)", isDirectory: true)
        into = scratch.appendingPathComponent("into", isDirectory: true)
        builds = scratch.appendingPathComponent("builds", isDirectory: true)
        for dir in [into!, builds!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        StubURLProtocol.handler = nil
        NoNetworkURLProtocol.requests = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        StubURLProtocol.handler = nil
    }

    private let payload = Data("the archive bytes".utf8)

    private func sha(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private func session(_ type: AnyClass) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [type]
        return URLSession(configuration: config)
    }

    /// No PADDOCK_BUILDS_DIR, and resources that hold no builds: only explicit sources resolve.
    private var emptyEnvironment: [String: String] {
        ["PADDOCK_RESOURCES": scratch.appendingPathComponent("no-resources").path]
    }

    private var localEnvironment: [String: String] {
        ["PADDOCK_BUILDS_DIR": builds.path, "PADDOCK_RESOURCES": scratch.appendingPathComponent("no-resources").path]
    }

    private func contents(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    func testDownloadsAndVerifies() async throws {
        StubURLProtocol.handler = { _ in self.payload }
        let downloader = ArtifactDownloader(session: session(StubURLProtocol.self), environment: emptyEnvironment)
        let artifact = Artifact(url: URL(string: "https://stub.test/a.tar.gz")!, sha256: sha(payload),
                                size: payload.count)
        var reported: [Double] = []
        let file = try await downloader.fetch(artifact, into: into) { reported.append($0) }
        XCTAssertEqual(try Data(contentsOf: file), payload)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL.path, into.standardizedFileURL.path)
        XCTAssertEqual(reported.last, 1)
    }

    func testChecksumMismatchLeavesNothing() async throws {
        StubURLProtocol.handler = { _ in self.payload }
        let downloader = ArtifactDownloader(session: session(StubURLProtocol.self), environment: emptyEnvironment)
        let artifact = Artifact(url: URL(string: "https://stub.test/a.tar.gz")!,
                                sha256: String(repeating: "0", count: 64), size: nil)
        do {
            _ = try await downloader.fetch(artifact, into: into, progress: nil)
            XCTFail("expected a checksum mismatch")
        } catch let error as ArtifactError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        XCTAssertEqual(contents(into), [])
    }

    func testSizeMismatchIsAChecksumMismatch() async throws {
        StubURLProtocol.handler = { _ in self.payload }
        let downloader = ArtifactDownloader(session: session(StubURLProtocol.self), environment: emptyEnvironment)
        let artifact = Artifact(url: URL(string: "https://stub.test/a.tar.gz")!, sha256: sha(payload),
                                size: payload.count + 1)
        do {
            _ = try await downloader.fetch(artifact, into: into, progress: nil)
            XCTFail("expected a mismatch")
        } catch let error as ArtifactError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        XCTAssertEqual(contents(into), [])
    }

    func testFailedDownloadIsDownloadFailedAndLeavesNothing() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        let downloader = ArtifactDownloader(session: session(StubURLProtocol.self), environment: emptyEnvironment)
        let artifact = Artifact(url: URL(string: "https://stub.test/a.tar.gz")!, sha256: sha(payload), size: nil)
        do {
            _ = try await downloader.fetch(artifact, into: into, progress: nil)
            XCTFail("expected a failure")
        } catch let error as ArtifactError {
            guard case .downloadFailed = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(contents(into), [])
    }

    func testLocalBuildIsCopiedAndVerifiedWithoutTheNetwork() async throws {
        let source = builds.appendingPathComponent("php-8.4.28-cli-macos-x86_64.tar.gz")
        try payload.write(to: source)
        let downloader = ArtifactDownloader(session: session(NoNetworkURLProtocol.self), environment: localEnvironment)
        let artifact = Artifact(url: URL(string: "paddock-builds://php-8.4.28-cli-macos-x86_64.tar.gz")!,
                                sha256: sha(payload), size: payload.count)
        let file = try await downloader.fetch(artifact, into: into, progress: nil)
        XCTAssertEqual(try Data(contentsOf: file), payload)
        XCTAssertNotEqual(file.path, source.path)
        XCTAssertEqual(try Data(contentsOf: source), payload, "the source must be left in place")
        XCTAssertEqual(NoNetworkURLProtocol.requests, 0)
    }

    func testLocalBuildWithTheWrongChecksumLeavesNothing() async throws {
        try payload.write(to: builds.appendingPathComponent("x.tar.gz"))
        let downloader = ArtifactDownloader(session: session(NoNetworkURLProtocol.self), environment: localEnvironment)
        let artifact = Artifact(url: URL(string: "paddock-builds://x.tar.gz")!,
                                sha256: String(repeating: "a", count: 64), size: nil)
        do {
            _ = try await downloader.fetch(artifact, into: into, progress: nil)
            XCTFail("expected a checksum mismatch")
        } catch let error as ArtifactError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        XCTAssertEqual(contents(into), [])
    }

    func testUnresolvableBuildIsNotAvailableAndNeverDownloads() async throws {
        let downloader = ArtifactDownloader(session: session(NoNetworkURLProtocol.self), environment: localEnvironment)
        let artifact = Artifact(url: URL(string: "paddock-builds://missing.tar.gz")!, sha256: sha(payload), size: nil)
        do {
            _ = try await downloader.fetch(artifact, into: into, progress: nil)
            XCTFail("expected notAvailable")
        } catch let error as ArtifactError {
            XCTAssertEqual(error, .notAvailable)
        }
        XCTAssertEqual(NoNetworkURLProtocol.requests, 0)
        XCTAssertEqual(contents(into), [])
    }

    func testCancelStopsTheDownloadAndLeavesNothing() async throws {
        let downloader = ArtifactDownloader(session: session(StallingURLProtocol.self), environment: emptyEnvironment)
        let artifact = Artifact(url: URL(string: "https://stub.test/a.tar.gz")!, sha256: sha(payload), size: nil)
        let into = self.into!
        let task = Task { try await downloader.fetch(artifact, into: into, progress: nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let began = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled fetch should throw")
        } catch let error as ArtifactError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        XCTAssertEqual(contents(into), [])
    }

    func testArtifactDecodesWithoutSize() throws {
        let json = #"{"url":"paddock-builds://a.tar.gz","sha256":"ab"}"#
        let artifact = try JSONDecoder().decode(Artifact.self, from: Data(json.utf8))
        XCTAssertNil(artifact.size)
        XCTAssertEqual(artifact.url.absoluteString, "paddock-builds://a.tar.gz")
    }
}
