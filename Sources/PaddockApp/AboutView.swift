import PaddockCore
import SwiftUI

/// The version and the full third-party notices.
struct AboutView: View {
    static let windowID = "about"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Paddock").font(.title2.weight(.heavy))
            Text("Version \(Self.version)").foregroundStyle(Theme.inkMuted)
            ScrollView {
                Text(Self.notices)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    /// `THIRD-PARTY-NOTICES` from the bundle's resources (the repo root when run from a build folder).
    static var notices: String {
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
