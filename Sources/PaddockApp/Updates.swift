import AppKit
import Combine
import Sparkle

/// Paddock's updates, by Sparkle: a check once a day and whenever asked, and its standard window, which shows
/// what is new and asks before installing. Every update is verified against the public key in Info.plist.
///
/// Only a built app updates itself: a development build (no feed address in its Info.plist) has no updater,
/// and the menu has no row for it.
@MainActor
final class Updates: ObservableObject {
    /// Whether a check can start now (not while one is under way).
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    /// Whether this build can update itself at all.
    var isAvailable: Bool { controller != nil }

    /// The menu's "Check for Updates…": Sparkle's window says what it found.
    func check() {
        // A menu-bar app is never in front on its own; the window would open behind the others.
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
