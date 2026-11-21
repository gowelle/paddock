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
            "add-trusted-cert", "-r", "trustRoot", "-k", "/Users/someone/Library/Keychains/login.keychain-db", root])])
    }

    func testTrustThrowsWhenCommandFails() {
        let runner = RecordingCommandRunner { _, _ in (1, "declined") }
        XCTAssertThrowsError(try trust(runner).trust()) {
            XCTAssertEqual($0 as? CertificateTrustError, .failed("declined"))
        }
    }

    func testIsTrustedMapsExitStatus() {
        let ok = RecordingCommandRunner { _, _ in (0, "") }
        XCTAssertTrue(trust(ok).isTrusted())
        XCTAssertEqual(ok.calls, [.init(executable: "/usr/bin/security", arguments: ["verify-cert", "-c", root])])
        XCTAssertFalse(trust(RecordingCommandRunner { _, _ in (3, "") }).isTrusted())
    }

    func testUntrustRunsRemoveTrustedCert() throws {
        let runner = RecordingCommandRunner()
        try trust(runner).untrust()
        XCTAssertEqual(runner.calls, [.init(executable: "/usr/bin/security", arguments: ["remove-trusted-cert", root])])
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
