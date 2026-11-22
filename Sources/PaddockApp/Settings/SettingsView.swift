import PaddockCore
import SwiftUI

/// The settings window: three tabs, nothing else.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var logs: LogsModel
    @Environment(\.openWindow) private var openWindow

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
        // A tab's Open Log chose a log: bring the Logs window forward to show it.
        .onChange(of: logs.openRequests) { _ in
            activateApp()
            openWindow(id: LogsView.windowID)
        }
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
        plainRows()
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

extension View {
    /// Without the system's alternating row stripes, which are white in the light appearance and would sit on
    /// the theme's surface as bars. (The system offers this from macOS 14; on 13 the stripes stay.)
    @ViewBuilder
    func plainRows() -> some View {
        if #available(macOS 14, *) {
            alternatingRowBackgrounds(.disabled)
        } else {
            self
        }
    }
}

/// Small secondary text under a table. Not `Caption`: a text that fixes its own height, beside a table, makes
/// the tab taller than its window and pushes the table's top out of view. This one takes the room it is given.
struct TableCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.inkMuted)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
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
