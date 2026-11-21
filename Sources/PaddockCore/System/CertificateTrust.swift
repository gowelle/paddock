import CryptoKit
import Foundation
import Security

/// Makes macOS trust Paddock's local certificate authority (Caddy's, under Paddock's name), for the
/// current user only.
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

    /// How long a trust change may wait (macOS may show a password dialog nobody answers); after that
    /// the `security` process is stopped and the change counts as not made.
    public static let changeTimeout: TimeInterval = 120

    /// Checked under the SSL policy, the only one `trust()` trusts the certificate for.
    public func isTrusted() -> Bool {
        isTrusted(rootCertificate)
    }

    /// Whether macOS trusts `certificate` (a file) for SSL.
    public func isTrusted(_ certificate: URL) -> Bool {
        (try? runner.run(Self.security, ["verify-cert", "-c", certificate.path, "-p", "ssl"]))?.status == 0
    }

    /// Trusts the root for SSL only (`-p ssl`), not for code signing, mail or anything else.
    public func trust() throws {
        try change(["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain.path, rootCertificate.path])
    }

    public func untrust() throws {
        try untrust(rootCertificate)
    }

    /// Removes the current user's trust settings for `certificate` (a file).
    public func untrust(_ certificate: URL) throws {
        try change(["remove-trusted-cert", certificate.path])
    }

    private func change(_ arguments: [String]) throws {
        let result = try runner.run(Self.security, arguments, environment: nil, timeout: Self.changeTimeout)
        guard result.status == 0 else {
            throw CertificateTrustError.failed(status: result.status, output: result.output)
        }
    }

    // MARK: - Roots replaced when the certificate authority was renamed

    /// Old roots set aside by `keepReplacedRoot`, oldest first: `<caddyData>/pki/replaced-root.crt`,
    /// `replaced-root-2.crt`, …
    public func replacedRoots() -> [URL] {
        Self.replacedRoots(paths: paths)
    }

    static func replacedRoots(paths: Paths) -> [URL] {
        let directory = replacedRootsDirectory(paths: paths)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in replacedRootIndex(name).map { ($0, name) } }
            .sorted { $0.0 < $1.0 }
            .map { directory.appendingPathComponent($0.1) }
    }

    private static func replacedRootsDirectory(paths: Paths) -> URL {
        paths.caddyData.appendingPathComponent("pki")
    }

    /// 1 for `replaced-root.crt`, n for `replaced-root-n.crt` (n >= 2), else nil.
    private static func replacedRootIndex(_ name: String) -> Int? {
        if name == "replaced-root.crt" { return 1 }
        guard name.hasPrefix("replaced-root-"), name.hasSuffix(".crt"),
              let n = Int(name.dropFirst("replaced-root-".count).dropLast(".crt".count)), n >= 2 else { return nil }
        return n
    }

    /// Moves `root` aside to a replaced-root file so its trust can be removed later, by the owner's own
    /// `paddock trust`, and returns where it is. A certificate already kept (same fingerprint) is not
    /// kept twice: `root` is then discarded and the existing file returned.
    static func keepReplacedRoot(_ root: URL, paths: Paths) throws -> URL {
        let existing = replacedRoots(paths: paths)
        let print = fingerprint(of: root)
        if let same = existing.first(where: { print != nil && fingerprint(of: $0) == print }) {
            try FileManager.default.removeItem(at: root)
            return same
        }
        let directory = replacedRootsDirectory(paths: paths)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var n = 1
        var target = directory.appendingPathComponent("replaced-root.crt")
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = directory.appendingPathComponent("replaced-root-\(n).crt")
        }
        try FileManager.default.moveItem(at: root, to: target)
        return target
    }

    /// Whether any replaced root is still trusted.
    public func hasTrustedReplacedRoots() -> Bool {
        replacedRoots().contains(where: isTrusted)
    }

    /// Removes trust from every replaced root that still has it, then deletes each replaced root that is
    /// no longer trusted (or never was). A file whose trust could not be removed stays for the next
    /// attempt. Returns one line per failure, for the log.
    @discardableResult
    public func cleanUpReplacedRoots() -> [String] {
        var failures: [String] = []
        for root in replacedRoots() {
            if isTrusted(root) {
                do { try untrust(root) } catch {
                    failures.append("removing trust from \(root.path) failed: \(error)")
                    continue
                }
                // Never delete a file macOS still trusts: it would then be impossible to clean up.
                if isTrusted(root) {
                    failures.append("macOS still trusts \(root.path) after remove-trusted-cert")
                    continue
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        return failures
    }

    // MARK: - Reading certificate files

    /// The subject common name of the first certificate in a PEM file, e.g.
    /// `Paddock Local Authority - Root`; nil if the file is missing or holds no readable certificate.
    /// Reads the file only; the keychain is not involved.
    public static func commonName(ofCertificateAt url: URL) -> String? {
        guard let der = der(ofCertificateAt: url),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    /// SHA-256 of the first certificate's DER bytes (of the whole file if it holds no PEM certificate).
    static func fingerprint(of url: URL) -> String? {
        guard let data = der(ofCertificateAt: url) ?? (try? Data(contentsOf: url)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func der(ofCertificateAt url: URL) -> Data? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex)
        else { return nil }
        return Data(base64Encoded: String(text[begin.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters)
    }
}

public enum CertificateTrustError: Error, Equatable {
    /// `security` exited with `status`, printing `output`.
    case failed(status: Int32, output: String)
}

extension CertificateTrustError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .failed(let status, let output):
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "security exited with status \(status)" + (text.isEmpty ? "" : ": \(text)")
        }
    }
}
