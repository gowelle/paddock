import Foundation

/// Decides whether Paddock may change the owner's system (keychain trust, resolver, launch agent).
/// A set `PADDOCK_HOME` marks a development or test home, which must never touch the system.
public enum SystemIntegration {
    public static func isEnabled(environment: [String: String]) -> Bool {
        environment["PADDOCK_HOME"].map(\.isEmpty) ?? true
    }
}
