import AppKit
import PaddockCore
import SwiftUI

/// The version, Paddock license, and full third-party notices.
struct AboutView: View {
    static let windowID = "about"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Paddock").font(Theme.heading(26))
            Text("Version \(Self.version)").foregroundStyle(Theme.inkMuted)
            TabView {
                textPanel("Paddock License", text: Self.license)
                    .tabItem { Text("License") }
                textPanel("Third-Party Notices", text: Self.notices)
                    .tabItem { Text("Third Party") }
            }
            .frame(height: 310)
        }
        .padding(20)
        .frame(width: 560, height: 500)
        .foregroundStyle(Theme.ink)
        .tint(Theme.honeyText)
        .background(Theme.ground)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    private func textPanel(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding([.top, .horizontal], 8)
            LongText(text: text)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    static let license = loadLicense()
    /// `THIRD-PARTY-NOTICES` from the bundle's resources (the repo root when run from a build folder).
    static let notices = loadNotices()

    private static func loadLicense() -> String {
        let candidates = [
            Bundled.resources.appendingPathComponent("LICENSE"),
            Bundled.resources.deletingLastPathComponent().appendingPathComponent("LICENSE"),
        ]
        for file in candidates {
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        }
        return "LICENSE is missing from this build."
    }

    private static func loadNotices() -> String {
        let candidates = [
            Bundled.resources.appendingPathComponent("THIRD-PARTY-NOTICES"),
            Bundled.resources.deletingLastPathComponent().appendingPathComponent("THIRD-PARTY-NOTICES"),
        ]
        for file in candidates {
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        }
        return "THIRD-PARTY-NOTICES is missing from this build."
    }
}

/// A long plain text, selectable and scrolling. The notices are thousands of lines: AppKit's text view lays out
/// only what is on show, where a SwiftUI `Text` measures all of it before drawing any.
struct LongText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.textContainer?.lineFragmentPadding = 0
        scroll.scrollerStyle = .overlay
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        view.textColor = NSColor(Theme.ink)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}
