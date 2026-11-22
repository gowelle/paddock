import AppKit
import PaddockCore
import SwiftUI

/// The menu bar menu: one plain view, shown in the menu bar panel and rendered by the snapshot tool.
struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var mail: MailModel
    @ObservedObject private var updates = AppDelegate.updates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeader()
            MenuDivider()

            SubmenuRow(title: "Sites", isEnabled: !model.sites.isEmpty) { siteItems }
            SubmenuRow(title: model.phpMenuTitle, isEnabled: !model.installedPHP.isEmpty) { phpItems }
            if mail.isAdded {
                MenuRow(mail.menuTitle) {
                    activateApp()
                    openWindow(id: MailView.windowID)
                }
            }
            MenuDivider()

            MenuRow("Logs") {
                activateApp()
                openWindow(id: LogsView.windowID)
            }
            MenuRow("Dumps") {
                activateApp()
                openWindow(id: DumpsView.windowID)
            }
            MenuRow("Open Sites Folder", isEnabled: model.sitesFolder != nil) {
                if let folder = model.sitesFolder { NSWorkspace.shared.open(folder) }
            }
            if model.isRunning {
                MenuRow("Stop", isEnabled: !model.isBusy(.stop)) { Task { await model.stop() } }
            } else {
                MenuRow("Start", isEnabled: !model.isBusy(.start)) {
                    Task { @MainActor in
                        guard AppDelegate.isLicenseAccepted else {
                            (NSApp.delegate as? AppDelegate)?.showLicenseAcceptance()
                            return
                        }
                        await model.start()
                    }
                }
            }
            MenuDivider()

            SettingsRow()
            MenuRow("About Paddock") {
                activateApp()
                openWindow(id: AboutView.windowID)
            }
            if updates.isAvailable {
                MenuRow("Check for Updates…", isEnabled: updates.canCheck) { updates.check() }
            }
            MenuDivider()
            MenuRow("Quit") { NSApp.terminate(nil) }

            if let error = model.lastError {
                MenuDivider()
                ErrorLine(text: error).padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .padding(.vertical, 5)
        .frame(width: 280)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface)
        .background(VisibilityReporter { visible in
            if visible {
                model.beginWatching()
                mail.beginWatching()
            } else {
                model.endWatching()
                mail.endWatching()
            }
        })
    }

    private var siteItems: [PopUpItem] {
        model.sites.map { site in
            PopUpItem(title: site.host, detail: "PHP \(site.php)", symbol: site.secured ? "lock.fill" : nil) {
                if let url = URL(string: site.url) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var phpItems: [PopUpItem] {
        model.installedPHP.map { version in
            PopUpItem(title: "PHP \(version)", checked: version == model.defaultPHP) {
                Task { await model.perform(.use(version: version)) }
            }
        }
    }
}

/// `Paddock` and its state; when ports are blocked, what holds them and what can be done.
private struct StatusHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(state: dotState)
                    .frame(width: 14, height: 14)
                Text(model.statusLine)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canQuitBlockingHolder {
                Button(model.quitButtonTitle) { Task { await model.quitBlockingHolder() } }
                    .controlSize(.small)
            } else if let explanation = model.blockedExplanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let title = model.setupActionTitle {
                Button(title) { Task { await model.finishSetup() } }
                    .controlSize(.small)
                    .disabled(model.isBusy(.start))
            }
            if let title = model.trustActionTitle {
                Button(title) { Task { await model.trustCertificate() } }
                    .controlSize(.small)
                    .disabled(model.isBusy(.trust))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var dotState: StatusDot.State {
        if model.isServing { return .running }
        return model.isBlocked ? .blocked : .stopped
    }
}

/// `Settings…`: SettingsLink on macOS 14 and later, the settings action on macOS 13.
private struct SettingsRow: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { MenuRowLabel(title: "Settings…") }
                .buttonStyle(MenuRowStyle())
                .simultaneousGesture(TapGesture().onEnded { activateApp() })
        } else {
            MenuRow("Settings…") {
                activateApp()
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

// MARK: - Menu-like rows

struct MenuRow: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) { MenuRowLabel(title: title) }
            .buttonStyle(MenuRowStyle())
            .disabled(!isEnabled)
    }
}

private struct MenuRowLabel: View {
    let title: String
    var showsChevron = false

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
        }
    }
}

/// Looks like a menu item: full width, highlighted in honey on hover.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @SwiftUI.State private var hovering = false

        var body: some View {
            let highlighted = isEnabled && (hovering || configuration.isPressed)
            configuration.label
                .foregroundStyle(highlighted ? Theme.onHoney
                                 : isEnabled ? Theme.ink : Theme.inkMuted.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(highlighted ? Theme.honey : Color.clear))
                .contentShape(Rectangle())
                .padding(.horizontal, 5)
                .onHover { hovering = $0 }
        }
    }
}

private struct MenuDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 4)
    }
}

// MARK: - Submenus

/// One item of a native pop-up submenu.
struct PopUpItem {
    var title: String
    var detail: String?
    var symbol: String?
    var checked = false
    var action: () -> Void

    init(title: String, detail: String? = nil, symbol: String? = nil, checked: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.checked = checked
        self.action = action
    }
}

/// A menu row with a chevron that opens a native submenu beside itself.
struct SubmenuRow: View {
    let title: String
    var isEnabled = true
    let items: () -> [PopUpItem]
    @SwiftUI.State private var anchor = AnchorView.Box()

    var body: some View {
        Button {
            if let view = anchor.view { PopUpMenu.show(items(), beside: view) }
        } label: {
            MenuRowLabel(title: title, showsChevron: true)
        }
        .buttonStyle(MenuRowStyle())
        .disabled(!isEnabled)
        .background(AnchorView(box: anchor))
    }
}

/// Gives SwiftUI code the AppKit view a row sits in, to anchor a pop-up menu to.
private struct AnchorView: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

@MainActor
private enum PopUpMenu {
    static func show(_ items: [PopUpItem], beside view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let tabStop = NSMutableParagraphStyle()
        tabStop.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
        for item in items {
            let menuItem = ClosureMenuItem(title: item.title, handler: item.action)
            if let detail = item.detail {
                let text = NSMutableAttributedString(string: item.title + "\t",
                                                     attributes: [.paragraphStyle: tabStop])
                text.append(NSAttributedString(string: detail, attributes: [
                    .paragraphStyle: tabStop, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                menuItem.attributedTitle = text
            }
            if let symbol = item.symbol {
                menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menuItem.state = item.checked ? .on : .off
            menu.addItem(menuItem)
        }
        let top = view.isFlipped ? 0 : view.bounds.height
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.width, y: top), in: view)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

// MARK: - Shared pieces

/// The one quiet line errors appear in.
struct ErrorLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Reports whether the window the view sits in is on screen, so the model refreshes only while it is.
struct VisibilityReporter: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) { nsView.onChange = onChange }

    final class ReportingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var visible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { report(false); return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportWindowState() }
            }
            reportWindowState()
        }

        private func reportWindowState() {
            report(window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
        }

        private func report(_ now: Bool) {
            guard now != visible else { return }
            visible = now
            onChange?(now)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
