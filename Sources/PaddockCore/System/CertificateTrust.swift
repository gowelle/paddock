import Foundation

/// Makes macOS trust Caddy's local certificate authority, for the current user only.
/// `trust()` makes macOS show its own confirmation; Paddock adds no prompt of its own.
public struct CertificateTrust: Sendable {
    public let paths: Paths
    let runner: CommandRunner
    let keychain: URL

    static let security = "/usr/bin/security"

    public init(paths: Paths, runner: CommandRunner,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.paths = paths
        self.runner = runner
        keychain = home.appendingPathComponent("Library/Keychains/login.keychain-db")
    }

    /// Where Caddy writes its root certificate (`storage file_system <caddyData>`).
    public var rootCertificate: URL {
        paths.caddyData.appendingPathComponent("pki/authorities/local/root.crt")
    }

    public func isTrusted() -> Bool {
        (try? runner.run(Self.security, ["verify-cert", "-c", rootCertificate.path]))?.status == 0
    }

    public func trust() throws {
        let result = try runner.run(Self.security, ["add-trusted-cert", "-r", "trustRoot",
                                                    "-k", keychain.path, rootCertificate.path])
        guard result.status == 0 else { throw CertificateTrustError.failed(result.output) }
    }

    public func untrust() throws {
        let result = try runner.run(Self.security, ["remove-trusted-cert", rootCertificate.path])
        guard result.status == 0 else { throw CertificateTrustError.failed(result.output) }
    }
}

public enum CertificateTrustError: Error, Equatable {
    case failed(String)
}
