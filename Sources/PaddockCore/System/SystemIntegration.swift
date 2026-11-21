import Foundation

/// Decides whether Paddock may change the owner's system (keychain trust, resolver, launch agent).
/// A set `PADDOCK_HOME` marks a development or test home, which must never touch the system.
public enum SystemIntegration {
    public static func isEnabled(environment: [String: String]) -> Bool {
        environment["PADDOCK_HOME"].map(\.isEmpty) ?? true
    }

    /// A program that may not change the owner's system or installed Paddock: on the real system
    /// (`isEnabled`) and not a bundled build, i.e. there is no `paddock-ports` of a Paddock.app it belongs
    /// to (`bundledHelper`, normally `PortHelperLocator.bundledBinary()`: the program is inside the `.app`,
    /// or is the `bin/` copy whose `.resources` names one). The one rule the lifecycle, the daemon and the
    /// client all use.
    public static func isDevelopmentBuild(environment: [String: String], bundledHelper: URL?) -> Bool {
        isEnabled(environment: environment) && bundledHelper == nil
    }

    /// The install a program belongs to: its outermost `.app`, else the folder it is in.
    public static func installLocation(of executable: String) -> String {
        PortHolder.enclosingApp(ofExecutable: executable)?.path
            ?? URL(fileURLWithPath: executable).deletingLastPathComponent().standardizedFileURL.path
    }

    /// `isDevelopmentBuild` for this process.
    public static var thisProcessIsDevelopmentBuild: Bool {
        isDevelopmentBuild(environment: ProcessInfo.processInfo.environment,
                           bundledHelper: PortHelperLocator.bundledBinary())
    }
}
