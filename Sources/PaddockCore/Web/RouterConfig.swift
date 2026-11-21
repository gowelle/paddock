import Foundation

/// Writes the Valet config the vendored router reads from `PADDOCK_ROUTER_HOME`.
public enum RouterConfig {
    public static func write(state: State, paths: Paths, settings: Settings) throws {
        let fm = FileManager.default
        let sitesDir = paths.routerHome.appendingPathComponent("Sites", isDirectory: true)
        try fm.createDirectory(at: sitesDir, withIntermediateDirectories: true)

        let config: [String: Any] = [
            "tld": settings.tld,
            "loopback": "127.0.0.1",
            "paths": state.parked + [sitesDir.path],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: paths.routerHome.appendingPathComponent("config.json"), options: .atomic)

        // Valet matches directory names case-sensitively against the lowercased host, so link
        // under the normalized name, like SiteRegistry.
        var wanted: [String: String] = [:]
        for (rawName, target) in state.links {
            guard let name = SiteName.normalize(rawName) else { continue }
            if wanted[name] != nil && rawName != name { continue }
            wanted[name] = target
        }

        for entry in try fm.contentsOfDirectory(atPath: sitesDir.path) where wanted[entry] == nil {
            let url = sitesDir.appendingPathComponent(entry)
            // Only remove symlinks; never touch a real directory someone put there.
            if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
                try fm.removeItem(at: url)
            }
        }
        for (name, target) in wanted {
            let url = sitesDir.appendingPathComponent(name)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                if existing == target { continue }
                try fm.removeItem(at: url)
            }
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }
}
