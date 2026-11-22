import Foundation

/// How `paddock service remove --delete-data` makes sure: on a terminal it asks for the service's name, typed
/// exactly; elsewhere it needs `--yes`.
public enum DeleteDataConfirmation: Equatable, Sendable {
    /// `--yes`: delete without asking.
    case proceed
    /// Ask on the terminal.
    case ask
    /// No terminal to ask on and no `--yes`: delete nothing.
    case refuse

    public static func decide(yes: Bool, interactive: Bool) -> DeleteDataConfirmation {
        if yes { return .proceed }
        return interactive ? .ask : .refuse
    }

    /// Only the service's name, exactly as Paddock shows it.
    public static func accepts(typed: String?, name: String) -> Bool {
        typed == name
    }

    /// What is said before asking.
    public static func prompt(name: String, dataPath: String) -> [String] {
        ["\(name): its data is in \(dataPath).", "This deletes its data permanently. Paddock keeps no backups."]
    }

    public static func question(name: String) -> String {
        "Type the service's name (\(name)) to delete it: "
    }

    public static let needsYes = "Add --yes to delete data without being asked."
    public static let notConfirmed = "The name didn't match, so nothing was removed or deleted."
}
