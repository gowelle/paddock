import Foundation

/// Decides which PHP a terminal command should run, from `state.json` and the installed builds alone:
/// no daemon and no manifest, so `php` stays fast.
public struct PHPResolver {
    private let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// The site's pin if the directory is inside a pinned site, else the default; the newest installed
    /// version when that one isn't installed or no default is stored. Nil only when nothing is installed.
    public func version(forDirectory directory: String) -> PHPVersion? {
        let installer = PHPInstaller(paths: paths, manifest: PHPManifest(builds: []),
                                     bundledResources: paths.home)
        let installed = installer.installed()
        guard let newest = installed.max() else { return nil }
        let state = StateStore(paths: paths).load()
        let fallback = state.defaultPHP ?? newest
        let wanted = SiteRegistry(state: state, defaultPHP: fallback)
            .site(containing: directory)?.php ?? fallback
        return installed.contains(wanted) ? wanted : newest
    }

    public func binary(forDirectory directory: String) -> URL? {
        guard let v = version(forDirectory: directory) else { return nil }
        return paths.phpDir(v).appendingPathComponent("php")
    }

    /// What loads Xdebug for `version`, when it is switched on and installed; none otherwise.
    public func xdebugArguments(for version: PHPVersion) -> [String] {
        Xdebug.arguments(for: version, state: StateStore(paths: paths).load(), paths: paths)
    }

    /// The user's php.ini for `version`, only if the file exists.
    public func ini(for version: PHPVersion) -> URL? {
        let ini = paths.phpIni(version)
        return FileManager.default.fileExists(atPath: ini.path) ? ini : nil
    }
}
