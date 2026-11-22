import PaddockCore
import SwiftUI

/// The settings window: three tabs, nothing else.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            PHPTab().tabItem { Label("PHP", systemImage: "chevron.left.forwardslash.chevron.right") }
            SitesTab().tabItem { Label("Sites", systemImage: "globe") }
            ServicesTab().tabItem { Label("Services", systemImage: "shippingbox") }
            TasksTab().tabItem { Label("Tasks", systemImage: "terminal") }
        }
        .frame(width: SettingsView.size.width, height: SettingsView.size.height)
        .settingsTheme()
        .background(VisibilityReporter { visible in
            visible ? model.beginWatching() : model.endWatching()
        })
    }

    static let size = CGSize(width: 540, height: 420)
}

extension View {
    /// The design system's ground, ink and accent for a settings tab, in the window or a snapshot.
    func settingsTheme() -> some View {
        foregroundStyle(Theme.ink)
            .tint(Theme.honeyText)
            .background(Theme.ground)
    }
}

extension View {
    /// A table drawn on the design system's surface, with a hairline edge, instead of the system's white.
    func tableSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

/// The error line at the foot of a settings tab.
struct SettingsFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let error = model.lastError {
            ErrorLine(text: error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }
}
