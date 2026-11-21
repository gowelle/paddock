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

    // MARK: - Bounded trust changes

    func testTrustChangesAreBoundedInTime() throws {
        let runner = RecordingCommandRunner()
        let t = trust(runner)
        try t.trust()
        try t.untrust()
        _ = t.isTrusted(URL(fileURLWithPath: "/x/replaced-root.crt"))
        XCTAssertEqual(runner.timeouts, [120, 120, 30], "every security call is bounded")
        XCTAssertEqual(CertificateTrust.changeTimeout, 120)
    }

    func testRunnerTimeoutTerminatesTheCommandAndReportsItNotCompleted() throws {
        let began = Date()
        XCTAssertThrowsError(try SystemCommandRunner().run("/bin/sleep", ["30"], environment: nil, timeout: 0.5)) {
            XCTAssertEqual($0 as? CommandRunnerError, .timedOut(executable: "/bin/sleep", seconds: 0.5))
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "terminated, not waited for")
        let quick = try SystemCommandRunner().run("/bin/echo", ["hi"], environment: nil, timeout: 5)
        XCTAssertEqual(quick.status, 0)
        XCTAssertEqual(quick.output, "hi\n")
    }

    // MARK: - Replaced roots

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/pdk-ct-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A self-signed certificate made by /usr/bin/openssl.
    private func makeCertificate(_ file: URL, name: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try SystemCommandRunner().run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", file.path + ".key", "-out", file.path, "-days", "1", "-subj", "/CN=\(name)"])
        XCTAssertEqual(result.status, 0, result.output)
        try? FileManager.default.removeItem(atPath: file.path + ".key")
    }

    func testAReplacedRootIsKeptOncePerCertificate() throws {
        let home = try tempDir()
        let paths = Paths(home: home)
        let t = CertificateTrust(paths: paths, runner: RecordingCommandRunner())
        XCTAssertEqual(t.replacedRoots(), [])

        try makeCertificate(t.rootCertificate, name: "Caddy Local Authority - 2026 ECC Root")
        let copy = try Data(contentsOf: t.rootCertificate)
        let kept = try CertificateTrust.keepReplacedRoot(t.rootCertificate, paths: paths)
        XCTAssertEqual(kept.path, paths.caddyData.appendingPathComponent("pki/replaced-root.crt").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.rootCertificate.path), "moved, not copied")
        XCTAssertEqual(CertificateTrust.commonName(ofCertificateAt: kept), "Caddy Local Authority - 2026 ECC Root")

        // The same certificate again: the one already kept stands, the newer file is discarded.
        try copy.write(to: t.rootCertificate)
        XCTAssertEqual(try CertificateTrust.keepReplacedRoot(t.rootCertificate, paths: paths), kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.rootCertificate.path))
        XCTAssertEqual(t.replacedRoots(), [kept])

        // A different certificate is kept beside it.
        try makeCertificate(t.rootCertificate, name: "Caddy Local Authority - 2027 ECC Root")
        let second = try CertificateTrust.keepReplacedRoot(t.rootCertificate, paths: paths)
        XCTAssertEqual(second.lastPathComponent, "replaced-root-2.crt")
        try makeCertificate(t.rootCertificate, name: "Caddy Local Authority - 2028 ECC Root")
        let third = try CertificateTrust.keepReplacedRoot(t.rootCertificate, paths: paths)
        XCTAssertEqual(third.lastPathComponent, "replaced-root-3.crt")
        XCTAssertEqual(t.replacedRoots().map(\.lastPathComponent),
                       ["replaced-root.crt", "replaced-root-2.crt", "replaced-root-3.crt"])
    }

    func testIsTrustedAndUntrustTakeTheCertificateGiven() throws {
        let runner = RecordingCommandRunner()
        let t = trust(runner)
        let old = URL(fileURLWithPath: "/h/Paddock/caddy/pki/replaced-root.crt")
        XCTAssertTrue(t.isTrusted(old))
        try t.untrust(old)
        XCTAssertEqual(runner.calls.map(\.arguments), [["verify-cert", "-c", old.path, "-p", "ssl"],
                                                      ["remove-trusted-cert", old.path]])
    }

    /// A keychain that trusts the listed files until `remove-trusted-cert` (if `removable`) untrusts them.
    private func keychain(trusted: Set<String>, removable: Bool = true) -> RecordingCommandRunner {
        let set = LockedBox(trusted)
        return RecordingCommandRunner { _, arguments in
            switch arguments.first {
            case "verify-cert": return set.value.contains(arguments[2]) ? (0, "") : notTrusted
            case "remove-trusted-cert":
                guard removable else { return (1, "User canceled the authorization") }
                set.value.remove(arguments[1])
                return (0, "")
            default: return (1, "unexpected")
            }
        }
    }

    func testCleaningUpRemovesTrustThenTheFileAndKeepsWhatIsStillTrusted() throws {
        let home = try tempDir()
        let paths = Paths(home: home)
        let pki = paths.caddyData.appendingPathComponent("pki")
        let trustedOld = pki.appendingPathComponent("replaced-root.crt")
        let untrustedOld = pki.appendingPathComponent("replaced-root-2.crt")
        try makeCertificate(trustedOld, name: "a")
        try makeCertificate(untrustedOld, name: "b")

        let runner = keychain(trusted: [trustedOld.path])
        let t = CertificateTrust(paths: paths, runner: runner)
        XCTAssertTrue(t.hasTrustedReplacedRoots())
        XCTAssertEqual(t.cleanUpReplacedRoots(), [])
        XCTAssertEqual(runner.calls.filter { $0.arguments.first == "remove-trusted-cert" }.map(\.arguments),
                       [["remove-trusted-cert", trustedOld.path]], "only the trusted one needed untrusting")
        XCTAssertEqual(t.replacedRoots(), [], "both files gone once neither is trusted")
        XCTAssertFalse(t.hasTrustedReplacedRoots())
    }

    func testARefusedUntrustKeepsTheFileForTheNextAttempt() throws {
        let home = try tempDir()
        let paths = Paths(home: home)
        let old = paths.caddyData.appendingPathComponent("pki/replaced-root.crt")
        try makeCertificate(old, name: "a")
        let t = CertificateTrust(paths: paths, runner: keychain(trusted: [old.path], removable: false))
        let failures = t.cleanUpReplacedRoots()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains(old.path) && failures[0].contains("User canceled"), failures[0])
        XCTAssertEqual(t.replacedRoots(), [old])
        XCTAssertTrue(t.hasTrustedReplacedRoots())
    }

    /// `verify-cert`'s three outcomes, as found on a scratch self-signed CA (never one in a keychain):
    /// exit 0 trusted; exit 1 with CSSMERR_TP_NOT_TRUSTED not trusted; anything else unknown.
    func testTrustStateDistinguishesTrustedNotTrustedAndUnknown() {
        func state(_ answer: (Int32, String)?) -> CertificateTrust.TrustState {
            let runner = RecordingCommandRunner { _, _ in answer ?? (0, "") }
            let throwing = ThrowingRunner()
            return trust(answer == nil ? throwing : runner).trustState(URL(fileURLWithPath: "/x/root.crt"))
        }
        XCTAssertEqual(state((0, "...certificate verification successful.")), .trusted)
        XCTAssertEqual(state((1, "Cert Verify Result: CSSMERR_TP_NOT_TRUSTED\n---")), .notTrusted)
        XCTAssertEqual(state((1, "***Error reading file /x/root.crt")), .unknown)
        XCTAssertEqual(state((1, "SecCertificateCreateFromData: Unknown format in import.")), .unknown)
        XCTAssertEqual(state((1, "Cert Verify Result: CSSMERR_TP_INVALID_CERTIFICATE")), .unknown)
        XCTAssertEqual(state((2, "")), .unknown)
        XCTAssertEqual(state(nil), .unknown, "the command failed or timed out")
    }

    /// A real, harmless run: a scratch CA certificate file no keychain knows is "not trusted", a missing
    /// file is "unknown". Read-only: `verify-cert` changes nothing.
    func testVerifyCertOnScratchFiles() throws {
        let dir = try tempDir()
        let ca = dir.appendingPathComponent("ca.crt")
        let made = try SystemCommandRunner().run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", dir.appendingPathComponent("ca.key").path,
            "-out", ca.path, "-days", "30", "-subj", "/CN=Paddock Test Scratch CA",
            "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        XCTAssertEqual(made.status, 0, made.output)
        let real = CertificateTrust(paths: Paths(home: dir), runner: SystemCommandRunner())
        XCTAssertEqual(real.trustState(ca), .notTrusted)
        XCTAssertEqual(real.trustState(dir.appendingPathComponent("missing.crt")), .unknown)
    }

    func testAnUnknownStateKeepsTheReplacedRoot() throws {
        let home = try tempDir()
        let paths = Paths(home: home)
        let old = paths.caddyData.appendingPathComponent("pki/replaced-root.crt")
        try makeCertificate(old, name: "a")
        let runner = RecordingCommandRunner { _, _ in (1, "***Error reading file") }
        let t = CertificateTrust(paths: paths, runner: runner)
        XCTAssertEqual(t.cleanUpReplacedRoots().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "unknown is not 'not trusted'")
        XCTAssertFalse(runner.calls.contains { $0.arguments.first == "remove-trusted-cert" })
    }

    func testAnUntrustThatReportsSuccessButLeavesTrustKeepsTheFile() throws {
        let home = try tempDir()
        let paths = Paths(home: home)
        let old = paths.caddyData.appendingPathComponent("pki/replaced-root.crt")
        try makeCertificate(old, name: "a")
        // remove-trusted-cert exits 0, but verify-cert still says trusted (e.g. trusted in another domain).
        let runner = RecordingCommandRunner { _, arguments in (arguments.first == "verify-cert" ? 0 : 0, "") }
        let t = CertificateTrust(paths: paths, runner: runner)
        XCTAssertEqual(t.cleanUpReplacedRoots().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "never deleted while still trusted")
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

/// A runner whose every command fails to run (or ran out of time).
private struct ThrowingRunner: CommandRunner {
    func run(_ executable: String, _ arguments: [String],
             environment: [String: String]?) throws -> (status: Int32, output: String) {
        throw CommandRunnerError.timedOut(executable: executable, seconds: 30)
    }
}
