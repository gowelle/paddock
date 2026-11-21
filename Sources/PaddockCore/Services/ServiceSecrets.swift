import Darwin
import Foundation
import Security

public enum ServiceSecretsError: Error, Equatable, Sendable {
    /// The secrets file is there but isn't one Paddock can use (not a plain file of this user's, unreadable,
    /// or holding a value Paddock wouldn't have made); nothing is generated over it.
    case damaged(path: String)
    /// macOS gave no random bytes.
    case noRandomness
}

/// The random values a recipe declares (`RecipeSecret`) for one instance, kept in its `config/secrets.json`
/// (mode 0600, in a config folder of mode 0700) as `{"<name>": "<URL-safe base64 without padding>"}`. Made
/// with the system's cryptographic random generator the first time an instance needs them, and never
/// replaced afterwards: a service's data may be protected by them. Never logged.
enum ServiceSecrets {
    static let fileName = "secrets.json"

    static func file(in config: URL) -> URL { config.appendingPathComponent(fileName) }

    /// The saved secrets; empty when there is no file.
    static func load(from config: URL) throws -> [String: String] {
        let path = file(in: config).path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return [:] }
            throw ServiceSecretsError.damaged(path: path)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw ServiceSecretsError.damaged(path: path)
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ServiceSecretsError.damaged(path: path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd(),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              values.allSatisfy({ isWellFormedName($0.key) && isWellFormedValue($0.value) }) else {
            throw ServiceSecretsError.damaged(path: path)
        }
        return values
    }

    /// The saved secrets with every declared one there: those missing are made and saved (atomically, mode
    /// 0600); the folder is made owner-only. Existing values are kept as they are.
    static func ensure(_ declared: [RecipeSecret], in config: URL) throws -> [String: String] {
        let fm = FileManager.default
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.path)
        var values = try load(from: config)
        let missing = declared.filter { values[$0.name] == nil }
        guard !missing.isEmpty else { return values }
        for secret in missing { values[secret.name] = try generate(bytes: secret.bytes) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let temporary = config.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: try encoder.encode(values),
                            attributes: [.posixPermissions: 0o600]) else {
            throw ServiceSecretsError.damaged(path: temporary.path)
        }
        guard rename(temporary.path, file(in: config).path) == 0 else {
            try? fm.removeItem(at: temporary)
            throw ServiceSecretsError.damaged(path: file(in: config).path)
        }
        return values
    }

    /// `bytes` random bytes from the system's cryptographic generator, URL-safe base64 without padding.
    static func generate(bytes: Int) throws -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer) == errSecSuccess else {
            throw ServiceSecretsError.noRandomness
        }
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isWellFormedName(_ name: String) -> Bool {
        name.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) != nil
    }

    /// What `generate` makes: at least 16 bytes' worth of URL-safe base64, nothing else (it ends up in
    /// `.env` lines and environments, so never a newline or a quote).
    static func isWellFormedValue(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{22,88}$", options: .regularExpression) != nil
    }
}
