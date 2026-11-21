import Foundation

/// The list of downloadable PHP builds (bundled with the app, or fetched from a URL).
public struct PHPManifest: Codable, Sendable {
    public struct Asset: Codable, Sendable, Equatable {
        public var url: URL
        public var sha256: String

        public init(url: URL, sha256: String) {
            self.url = url
            self.sha256 = sha256
        }
    }

    public struct Build: Codable, Sendable, Equatable {
        public var version: PHPVersion
        public var patch: String
        public var variant: String
        public var cli: Asset
        public var fpm: Asset

        public init(version: PHPVersion, patch: String, variant: String, cli: Asset, fpm: Asset) {
            self.version = version
            self.patch = patch
            self.variant = variant
            self.cli = cli
            self.fpm = fpm
        }
    }

    public var builds: [Build]

    public init(builds: [Build]) {
        self.builds = builds
    }

    public static func bundled() throws -> PHPManifest {
        let data = try Data(contentsOf: Bundled.resources.appendingPathComponent("php-manifest.json"))
        return try JSONDecoder().decode(PHPManifest.self, from: data)
    }

    public static func remote(_ url: URL, session: URLSession = .shared) async throws -> PHPManifest {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(PHPManifest.self, from: data)
    }

    public func build(for v: PHPVersion, variant: String = "default") -> Build? {
        builds.first { $0.version == v && $0.variant == variant }
    }
}
