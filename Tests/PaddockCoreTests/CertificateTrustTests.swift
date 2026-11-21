import PaddockTestSupport
import XCTest
@testable import PaddockCore

final class CertificateTrustTests: XCTestCase {
    private let paths = Paths(home: URL(fileURLWithPath: "/h/Paddock", isDirectory: true))
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let root = "/h/Paddock/caddy/pki/authorities/local/root.crt"

    private func trust(_ runner: CommandRunner) -> CertificateTrust {
        CertificateTrust(paths: paths, runner: runner, home: home)
    }

    func testRootCertificateLivesInCaddyData() {
        XCTAssertEqual(trust(RecordingCommandRunner()).rootCertificate.path, root)
    }

    func testTrustRunsExactlyOneAddTrustedCert() throws {
        let runner = RecordingCommandRunner()
        try trust(runner).trust()
        XCTAssertEqual(runner.calls, [.init(executable: "/usr/bin/security", arguments: [
            "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
            "-k", "/Users/someone/Library/Keychains/login.keychain-db", root])])
    }

    func testTrustThrowsWhenCommandFails() {
        let runner = RecordingCommandRunner { _, _ in (1, "declined") }
        XCTAssertThrowsError(try trust(runner).trust()) {
            XCTAssertEqual($0 as? CertificateTrustError, .failed(status: 1, output: "declined"))
        }
    }

    func testIsTrustedMapsExitStatus() {
        let ok = RecordingCommandRunner { _, _ in (0, "") }
        XCTAssertTrue(trust(ok).isTrusted())
        // Trust is for SSL only, so it is checked under the SSL policy.
        XCTAssertEqual(ok.calls, [.init(executable: "/usr/bin/security",
                                        arguments: ["verify-cert", "-c", root, "-p", "ssl"])])
        XCTAssertFalse(trust(RecordingCommandRunner { _, _ in (3, "") }).isTrusted())
    }

    func testUntrustRunsRemoveTrustedCert() throws {
        let runner = RecordingCommandRunner()
        try trust(runner).untrust()
        XCTAssertEqual(runner.calls, [.init(executable: "/usr/bin/security", arguments: ["remove-trusted-cert", root])])
    }

    func testCommonNameIsReadFromAPEMCertificate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdk-cn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cert = dir.appendingPathComponent("root.crt")
        let openssl = try SystemCommandRunner().run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", dir.appendingPathComponent("root.key").path, "-out", cert.path, "-days", "1",
            "-subj", "/CN=Caddy Local Authority - 2026 ECC Root"])
        XCTAssertEqual(openssl.status, 0, openssl.output)
        XCTAssertEqual(CertificateTrust.commonName(ofCertificateAt: cert), "Caddy Local Authority - 2026 ECC Root")
        XCTAssertNil(CertificateTrust.commonName(ofCertificateAt: dir.appendingPathComponent("missing.crt")))
        try Data("not a certificate".utf8).write(to: cert)
        XCTAssertNil(CertificateTrust.commonName(ofCertificateAt: cert))
    }

    func testSystemIntegrationFollowsPaddockHome() {
        XCTAssertTrue(SystemIntegration.isEnabled(environment: [:]))
        XCTAssertTrue(SystemIntegration.isEnabled(environment: ["PADDOCK_HOME": ""]))
        XCTAssertFalse(SystemIntegration.isEnabled(environment: ["PADDOCK_HOME": "/tmp/x"]))
        XCTAssertFalse(SystemIntegration.isEnabled(environment: ["PADDOCK_HOME": "/tmp/x", "PADDOCK_TRUST": "1"]))
    }

    func testSystemRunnerDrainsLargeOutputAndReportsStatus() throws {
        // More than a pipe buffer (64 KiB): hangs if the runner waits before reading.
        let big = try SystemCommandRunner().run("/usr/bin/head", ["-c", "300000", "/dev/zero"])
        XCTAssertEqual(big.status, 0)
        XCTAssertEqual(big.output.utf8.count, 300_000)
        XCTAssertEqual(try SystemCommandRunner().run("/usr/bin/false", []).status, 1)
    }
}
