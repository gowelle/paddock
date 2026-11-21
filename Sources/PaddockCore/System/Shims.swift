import Darwin
import Foundation

/// The terminal side of Paddock: `bin/paddock` plus `bin/php` and `bin/composer` linking to it.
enum Shims {
    /// Copies `source` to `<bin>/paddock`, links `php` and `composer` to it (relative links), and records
    /// where the bundled resources are in `<bin>/.resources`. A missing `source` does nothing.
    /// Every step replaces its target atomically, so running shims never see a half-written file.
    static func install(paths: Paths, source: URL?, resources: URL) throws {
        let fm = FileManager.default
        guard let source, fm.isExecutableFile(atPath: source.path) else { return }
        try fm.createDirectory(at: paths.bin, withIntermediateDirectories: true)

        let target = paths.bin.appendingPathComponent("paddock")
        if !isIdentical(source, target) {
            let temp = paths.bin.appendingPathComponent(".paddock-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: source, to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            try rename(temp, to: target)
        }

        for name in ["php", "composer"] {
            let link = paths.bin.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == "paddock" { continue }
            let temp = paths.bin.appendingPathComponent(".\(name)-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try fm.createSymbolicLink(atPath: temp.path, withDestinationPath: "paddock")
            try rename(temp, to: link)
        }

        let record = paths.bin.appendingPathComponent(".resources")
        let wanted = Data(resources.path.utf8)
        if (try? Data(contentsOf: record)) != wanted { try wanted.write(to: record, options: .atomic) }
    }

    private static func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isIdentical(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: b.path), let sa = try? fm.attributesOfItem(atPath: a.path),
              let sb = try? fm.attributesOfItem(atPath: b.path),
              (sa[.size] as? Int) == (sb[.size] as? Int) else { return false }
        return fm.contentsEqual(atPath: a.path, andPath: b.path)
    }
}
