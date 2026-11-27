import Foundation

/// Writes the Valet config the vendored router reads from `PADDOCK_ROUTER_HOME`.
public enum RouterConfig {
    public static func write(state: State, paths: Paths, settings: Settings) throws {
        let fm = FileManager.default
        let sitesDir = paths.routerHome.appendingPathComponent("Sites", isDirectory: true)
        try fm.createDirectory(at: sitesDir, withIntermediateDirectories: true)

        let config: [String: Any] = [
            "tld": settings.tld,
            "lan_domain": LAN.domain,
            "loopback": "127.0.0.1",
            // Sites first so links win over parked folders, as in SiteRegistry.
            "paths": [sitesDir.path] + state.parked,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: paths.routerHome.appendingPathComponent("config.json"), options: .atomic)

        // Valet matches directory names case-sensitively against the lowercased host, so link
        // under the normalized name, like SiteRegistry.
        var wanted: [String: String] = [:]
        for rawName in SiteName.claimOrder(Array(state.links.keys)) {
            guard let target = state.links[rawName], let name = SiteName.normalize(rawName),
                  wanted[name] == nil, isDirectory(target, fm) else { continue }
            wanted[name] = target
        }
        for (name, folder) in parkedFoldersNeedingLinks(state.parked, fileManager: fm)
        where wanted[name] == nil {
            wanted[name] = folder
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

    /// The router finds parked sites by folder name, but a site is named `SiteName.normalize(folder)`.
    /// Returns site name -> folder path for each parked folder that the router would not find under
    /// its site name. Earlier parked paths win; within one, `SiteName.claimOrder` decides.
    static func parkedFoldersNeedingLinks(_ parked: [String], fileManager fm: FileManager) -> [String: String] {
        var claimed = Set<String>()
        var links: [String: String] = [:]
        for parkedPath in parked {
            let entries = ((try? fm.contentsOfDirectory(atPath: parkedPath)) ?? []).filter { entry in
                var isDir: ObjCBool = false
                return !entry.hasPrefix(".")
                    && fm.fileExists(atPath: parkedPath + "/" + entry, isDirectory: &isDir) && isDir.boolValue
            }
            let ordered = SiteName.claimOrder(entries).compactMap { entry in SiteName.normalize(entry).map { (entry, $0) } }
            for (folder, name) in ordered where !claimed.contains(name) {
                claimed.insert(name)
                if folder != name {
                    links[name] = URL(fileURLWithPath: parkedPath).appendingPathComponent(folder).path
                }
            }
        }
        return links
    }

    private static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
