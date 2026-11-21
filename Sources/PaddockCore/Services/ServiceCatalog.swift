import Foundation

/// One kind of service as the catalog lists it.
public struct CatalogEntry: Codable, Equatable, Sendable {
    public let kind: String
    public let displayName: String
    public let licence: String
    /// Newest first.
    public let versions: [String]
    /// The newest version's download, in bytes, when every asset's size is known.
    public let downloadBytes: Int?

    public init(kind: String, displayName: String, licence: String, versions: [String], downloadBytes: Int?) {
        self.kind = kind
        self.displayName = displayName
        self.licence = licence
        self.versions = versions
        self.downloadBytes = downloadBytes
    }
}

/// The services Paddock can add: one recipe per service version.
public struct ServiceCatalog: Codable, Equatable, Sendable {
    public static let fileName = "services-catalog.json"
    /// A development home may name another catalog file (tests use a fake service).
    public static let overrideVariable = "PADDOCK_SERVICES_CATALOG"

    public let recipes: [ServiceRecipe]

    public init(recipes: [ServiceRecipe]) {
        self.recipes = recipes
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
    /// otherwise the bundled one (empty if it can't be read).
    public static func forDaemon(environment: [String: String]) -> ServiceCatalog {
        if !SystemIntegration.isEnabled(environment: environment),
           let path = environment[overrideVariable], !path.isEmpty,
           let catalog = try? load(from: URL(fileURLWithPath: path)) {
            return catalog
        }
        return (try? bundled()) ?? ServiceCatalog(recipes: [])
    }

    /// <repo>/Sources/PaddockCore/Services/ServiceCatalog.swift -> <repo>/Resources
    private static var repoResources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    /// The recipe for `kind` (any case): the newest version when `version` is nil; else exactly that
    /// version, or the newest whose version starts with it (`16` finds `16.4`).
    public func recipe(kind: String, version: String?) -> ServiceRecipe? {
        let candidates = recipes(of: kind)
        guard let version else { return candidates.first }
        return candidates.first { $0.version == version } ?? candidates.first { $0.version.hasPrefix(version + ".") }
    }

    /// The recipes of one kind, newest first.
    public func recipes(of kind: String) -> [ServiceRecipe] {
        recipes.filter { $0.kind.lowercased() == kind.lowercased() }
            .sorted { Self.isNewer($0.version, than: $1.version) }
    }

    /// Every kind, alphabetically, with its versions newest first.
    public func kinds() -> [CatalogEntry] {
        var seen: [String] = []
        for recipe in recipes where !seen.contains(recipe.kind) { seen.append(recipe.kind) }
        return seen.sorted().compactMap { kind in
            let versions = recipes(of: kind)
            guard let newest = versions.first else { return nil }
            let sizes = newest.assets.map(\.artifact.size)
            let bytes: Int? = sizes.contains { $0 == nil } ? nil : sizes.compactMap { $0 }.reduce(0, +)
            return CatalogEntry(kind: kind, displayName: newest.displayName, licence: newest.licence,
                                versions: versions.map(\.version), downloadBytes: bytes)
        }
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
