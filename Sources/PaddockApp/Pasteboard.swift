import AppKit

/// The general pasteboard, for the model's `copyText`.
@MainActor
enum Pasteboard {
    /// The marker clipboard managers honour to leave an item out of their history (nspasteboard.org).
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Puts `text` on the pasteboard; `concealed` (it holds a secret) also declares the concealed marker.
    static func copy(_ text: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes(concealed ? [.string, concealedType] : [.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        if concealed { pasteboard.setString("", forType: concealedType) }
    }
}
