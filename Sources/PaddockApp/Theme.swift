import AppKit
import CoreText
import PaddockCore
import SwiftUI

/// Paddock's colours, from the Paddock Design System: each follows the light or dark appearance.
enum Theme {
    /// Window background.
    static let ground = dynamic(light: 0xE8E3D9, dark: 0x1A1610)
    /// Raised panels: the menu, table bodies, text wells.
    static let surface = dynamic(light: 0xF3EFE7, dark: 0x262017)
    /// Decorative hairlines.
    static let line = dynamic(light: 0xC9C1B2, dark: 0x3A3226)
    /// Control edges and the stopped status ring.
    static let lineStrong = dynamic(light: 0x857A68, dark: 0x8A7C66)
    /// Primary text.
    static let ink = dynamic(light: 0x2B2014, dark: 0xEFE6D6)
    /// Captions, details and the quiet error line.
    static let inkMuted = dynamic(light: 0x5C5041, dark: 0xB8AA94)
    /// The brand colour, as a fill only.
    static let honey = dynamic(light: 0xD49A1E, dark: 0xE2AD3F)
    /// Text on honey fills, in both appearances.
    static let onHoney = dynamic(light: 0x2B2014, dark: 0x2B2014)
    /// Honey as text, and the edge of honey shapes.
    static let honeyText = dynamic(light: 0x7A5200, dark: 0xE6B655)
    /// Running, secured, checked.
    static let pasture = dynamic(light: 0x2F6659, dark: 0x7FB8A6)
    /// The halo round the running dot.
    static let pastureTint = dynamic(light: 0xCDDFD6, dark: 0x17332C)

    // MARK: - Type

    /// The brand's headline face. Only headings use it; menus, tables, body text and controls keep the system font.
    static let headingFamily = "Bricolage Grotesque"
    private static let headingFile = "fonts/BricolageGrotesque.ttf"

    /// Makes the headline face available to this app alone (nothing is installed on the Mac). Call once, before
    /// any view is made. In the app it is in the bundle's resources; run from a build folder, in the repository's.
    @discardableResult
    static func registerFonts() -> Bool {
        let candidates = [
            Bundled.resources.appendingPathComponent(headingFile),
            Bundled.resources.deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(headingFile),
        ]
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        return CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
    }

    /// A heading in the headline face: heavy, and drawn for its size (the face has an optical-size axis). Falls
    /// back to the system's heavy weight where the face is not there.
    static func heading(_ size: CGFloat) -> Font {
        // The face's variation axes, by their four-letter tags: 'wght' and 'opsz'.
        let weight = 0x7767_6874, opticalSize = 0x6F70_737A
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: headingFamily,
            .variation: [weight: 800, opticalSize: min(max(Double(size), 12), 96)],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == headingFamily else {
            return .system(size: size, weight: .heavy)
        }
        return Font(font)
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: Int) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

/// The dot in front of the status line: running, blocked and stopped differ in shape as well as colour.
struct StatusDot: View {
    enum State { case running, blocked, stopped }
    let state: State

    var body: some View {
        switch state {
        case .running:
            Circle().fill(Theme.pasture)
                .frame(width: 8, height: 8)
                .background(Circle().fill(Theme.pastureTint).frame(width: 14, height: 14))
        case .blocked:
            Circle().fill(Theme.honey)
                .overlay(Circle().strokeBorder(Theme.honeyText, lineWidth: 2))
                .frame(width: 8, height: 8)
        case .stopped:
            Circle().strokeBorder(Theme.lineStrong, lineWidth: 2)
                .frame(width: 8, height: 8)
        }
    }
}
