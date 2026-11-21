import Foundation

/// A PHP major.minor version such as "8.4". Encodes as that string.
/// Accepts "8.4", "8.4.8", "php@8.4" and "84"; only 8.1 and later are valid.
public struct PHPVersion: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public init?(_ s: String) {
        var text = s.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("php@") { text.removeFirst(4) }
        let major: Int
        let minor: Int
        if text.contains(".") {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let ma = Int(parts[0]), let mi = Int(parts[1]) else { return nil }
            major = ma
            minor = mi
        } else {
            guard text.count == 2, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
                  let n = Int(text) else { return nil }
            major = n / 10
            minor = n % 10
        }
        guard (major, minor) >= (8, 1) else { return nil }
        self.init(major: major, minor: minor)
    }

    public var description: String { "\(major).\(minor)" }

    public static func < (a: PHPVersion, b: PHPVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = PHPVersion(s) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid PHP version: \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
