import Foundation

/// Writes a service's lines into a site's `.env`, refusing what it can't do safely. Nothing is created and
/// nothing is written when it refuses.
public enum EnvFile {
    /// Why a write was refused or failed. The reason travels as the system's own sentence and never as any
    /// byte of the file.
    public enum Problem: Error, Equatable {
        case missing
        case symlink
        case notUTF8
        case unreadable(String)
        case unwritable(String)
    }

    public static func wire(_ lines: [String], intoSiteAt sitePath: String) throws -> EnvWiring.Result {
        let url = URL(fileURLWithPath: sitePath, isDirectory: true).appendingPathComponent(".env")
        // Before `fileExists`: a path inside a symlinked folder fails that check and would be reported missing.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw Problem.symlink
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Problem.missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Problem.unreadable(reason(error))
        }
        guard let existing = String(data: data, encoding: .utf8) else { throw Problem.notUTF8 }
        let result = EnvWiring.merge(existing: existing, service: lines)
        guard result.text != existing else { return result }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do {
            try Data(result.text.utf8).write(to: url, options: .atomic)
        } catch {
            throw Problem.unwritable(reason(error))
        }
        // `Data.write` replaces the file with a new one, which starts under the process umask, not `.env`'s
        // existing mode.
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return result
    }

    /// The system's sentence for a file error, falling back so the message always names a reason.
    private static func reason(_ error: Error) -> String {
        let sentence = error.localizedDescription
        return sentence.isEmpty ? "unknown error" : sentence
    }
}
