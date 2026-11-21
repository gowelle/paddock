import Foundation

/// One series of a kind, as the catalog lists it: its newest version and whether adding it downloads.
public struct CatalogSeries: Codable, Equatable, Sendable {
    public let series: String
    /// The newest version of the series.
    public let version: String
    /// Its download, in bytes, when every asset's size is known (0 when it downloads nothing).
    public let downloadBytes: Int?
    /// Whether adding it would download (false when installed already, or every file is on this Mac).
    public let needsDownload: Bool

    public init(series: String, version: String, downloadBytes: Int?, needsDownload: Bool) {
        self.series = series
        self.version = version
        self.downloadBytes = downloadBytes
        self.needsDownload = needsDownload
    }
}

/// One kind of service as the catalog lists it.
public struct CatalogEntry: Codable, Equatable, Sendable {
    public let kind: String
    public let displayName: String
    public let licence: String
    /// Every version, newest first.
    public let versions: [String]
    /// The newest version's download, in bytes, when every asset's size is known.
    public let downloadBytes: Int?
    /// Its series, newest first.
    public var series: [CatalogSeries]

    public init(kind: String, displayName: String, licence: String, versions: [String], downloadBytes: Int?,
                series: [CatalogSeries] = []) {
        self.kind = kind
        self.displayName = displayName
        self.licence = licence
        self.versions = versions
        self.downloadBytes = downloadBytes
        self.series = series
    }

    private enum CodingKeys: String, CodingKey { case kind, displayName, licence, versions, downloadBytes, series }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        displayName = try c.decode(String.self, forKey: .displayName)
        licence = try c.decode(String.self, forKey: .licence)
        versions = try c.decodeIfPresent([String].self, forKey: .versions) ?? []
        downloadBytes = try c.decodeIfPresent(Int.self, forKey: .downloadBytes)
        series = try c.decodeIfPresent([CatalogSeries].self, forKey: .series) ?? []
    }

    /// The series `typed` names: a series (`18`), a version of one (`18.1`), or the newest when nil.
    public func series(matching typed: String?) -> CatalogSeries? {
        guard let typed else { return series.first }
        return series.first { $0.series == typed } ?? series.first { $0.version == typed }
            ?? series.first { typed.hasPrefix($0.series + ".") }
    }
}

public enum ServiceCatalogError: Error, Equatable, CustomStringConvertible {
    /// The whole catalog is refused; the message names the recipe and the problem.
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): return "Paddock's service catalog is invalid: \(message)"
        }
    }
}

/// The services Paddock can add: one recipe per service version.
public struct ServiceCatalog: Codable, Equatable, Sendable {
    public static let fileName = "services-catalog.json"
    /// A development home may name another catalog file (tests use a fake service).
    public static let overrideVariable = "PADDOCK_SERVICES_CATALOG"

    public let recipes: [ServiceRecipe]

    /// Not validated: `ServiceManager` validates the catalog it is given, decoding validates a loaded one.
    public init(recipes: [ServiceRecipe]) {
        self.recipes = recipes
    }

    private enum CodingKeys: String, CodingKey { case recipes }

    /// Decoding validates: a catalog with any problem is refused as a whole.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try c.decode([ServiceRecipe].self, forKey: .recipes)
        try Self.validate(recipes)
    }

    /// The catalog shipped with Paddock: `services-catalog.json` in the bundled resources, or in the
    /// repository's `Resources/` for a build that runs from it.
    public static func bundled() throws -> ServiceCatalog {
        let candidates = [Bundled.resources.appendingPathComponent(fileName), repoResources.appendingPathComponent(fileName)]
        let file = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
        return try load(from: file)
    }

    public static func load(from file: URL) throws -> ServiceCatalog {
        try JSONDecoder().decode(ServiceCatalog.self, from: Data(contentsOf: file))
    }

    /// The daemon's catalog: in a development home, the file `PADDOCK_SERVICES_CATALOG` names if set;
    /// otherwise the bundled one (empty if it can't be read or isn't valid).
    public static func forDaemon(environment: [String: String]) -> ServiceCatalog {
        if !SystemIntegration.isEnabled(environment: environment),
           let path = environment[overrideVariable], !path.isEmpty {
            do { return try load(from: URL(fileURLWithPath: path)) } catch {
                fputs("paddockd: ignoring \(path): \(error)\n", stderr)
            }
        }
        do { return try bundled() } catch {
            fputs("paddockd: \(error)\n", stderr)
            return ServiceCatalog(recipes: [])
        }
    }

    /// <repo>/Sources/PaddockCore/Services/ServiceCatalog.swift -> <repo>/Resources
    private static var repoResources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    /// The recipe for `kind` (any case): the newest version when `version` is nil; else exactly that
    /// version, or the newest of the series it names (`16`, `8.4`), or the newest whose version starts with it.
    public func recipe(kind: String, version: String?) -> ServiceRecipe? {
        let candidates = recipes(of: kind)
        guard let version else { return candidates.first }
        return candidates.first { $0.version == version } ?? candidates.first { $0.series == version }
            ?? candidates.first { $0.version.hasPrefix(version + ".") }
    }

    /// The newest recipe of a series.
    public func recipe(kind: String, series: String) -> ServiceRecipe? {
        recipes(of: kind).first { $0.series == series }
    }

    /// The recipes of one kind, newest first.
    public func recipes(of kind: String) -> [ServiceRecipe] {
        recipes.filter { $0.kind.lowercased() == kind.lowercased() }
            .sorted { Self.isNewer($0.version, than: $1.version) }
    }

    /// Every kind, alphabetically, with its versions and series newest first. `needsDownload` says whether
    /// the series' newest version has anything to download (`ServiceManager` refines it with what's installed).
    /// `downloadBytes` is what adding a recipe downloads (every asset's size, unless the caller knows some
    /// are on this Mac already).
    public func kinds(needsDownload: (ServiceRecipe) -> Bool = { !$0.assets.isEmpty },
                      downloadBytes: (ServiceRecipe) -> Int? = { ServiceCatalog.downloadBytes($0.assets) }) -> [CatalogEntry] {
        var seen: [String] = []
        for recipe in recipes where !seen.contains(recipe.kind) { seen.append(recipe.kind) }
        return seen.sorted().compactMap { kind in
            let versions = recipes(of: kind)
            guard let newest = versions.first else { return nil }
            var series: [CatalogSeries] = []
            for recipe in versions where !series.contains(where: { $0.series == recipe.series }) {
                series.append(CatalogSeries(series: recipe.series, version: recipe.version,
                                            downloadBytes: downloadBytes(recipe), needsDownload: needsDownload(recipe)))
            }
            return CatalogEntry(kind: kind, displayName: newest.displayName, licence: newest.licence,
                                versions: versions.map(\.version), downloadBytes: downloadBytes(newest),
                                series: series)
        }
    }

    /// The assets' sizes added up, when every one is known.
    public static func downloadBytes(_ assets: [RecipeAsset]) -> Int? {
        let sizes = assets.map(\.artifact.size)
        return sizes.contains { $0 == nil } ? nil : sizes.compactMap { $0 }.reduce(0, +)
    }

    /// Whether `a` is a later version than `b`, comparing numeric parts as numbers (`1.10` > `1.9`).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let parts = { (v: String) in v.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init) }
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : "0"
            let r = index < right.count ? right[index] : "0"
            if let ln = Int(l), let rn = Int(r) {
                if ln != rn { return ln > rn }
            } else if l != r {
                return l > r
            }
        }
        return false
    }
}
