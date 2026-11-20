import Foundation

/// A PHP major.minor version such as "8.4". Encodes as that string.
/// Parsing is extended in a later task.
public struct PHPVersion: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public init?(_ s: String) {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]),
              major >= 0, minor >= 0 else { return nil }
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
