import AppKit
import PaddockCore
import SwiftUI

/// `PaddockApp --snapshots <dir>`: renders the menu and each settings tab from fixed sample states to
/// PNG files, in light and dark appearance, so the look can be reviewed without running Paddock.
@MainActor
enum Snapshots {
    static func write(to directory: URL) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Can't create \(directory.path): \(error)\n".utf8))
            return false
        }

        let running = sampleModel(.running)
        let shots: [(String, AnyView, CGSize?)] = [
            ("menu-running", AnyView(MenuContentView().environmentObject(running)), nil),
            ("menu-blocked", AnyView(MenuContentView().environmentObject(sampleModel(.blocked))), nil),
            ("menu-stopped", AnyView(MenuContentView().environmentObject(sampleModel(.stopped))), nil),
            ("settings-general", AnyView(GeneralTab().environmentObject(running)), SettingsView.size),
            ("settings-php", AnyView(PHPTab().environmentObject(running)), SettingsView.size),
            ("settings-sites", AnyView(SitesTab().environmentObject(running)), SettingsView.size),
        ]
        var ok = true
        for (name, view, size) in shots {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let file = directory.appendingPathComponent("\(name)-\(suffix).png")
                if render(view, size: size, appearance: appearance, to: file) {
                    print(file.path)
                } else {
                    FileHandle.standardError.write(Data("Couldn't render \(file.path)\n".utf8))
                    ok = false
                }
            }
        }
        return ok
    }

    /// Hosts the view in an off-screen window (so AppKit-backed controls such as tables, toggles and
    /// pickers draw for real) and captures it at 2x.
    private static func render(_ view: AnyView, size: CGSize?, appearance: NSAppearance.Name, to file: URL) -> Bool {
        let content = view
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        let frameSize = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: frameSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let tables load their rows and the layout settle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        host.display()

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frameSize.width * 2),
                                         pixelsHigh: Int(frameSize.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = frameSize
        var drawn = false
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
            drawn = true
        }
        guard drawn, let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }

    // MARK: - Sample states

    enum Sample { case running, blocked, stopped }

    private static let v84 = PHPVersion(major: 8, minor: 4)
    private static let v85 = PHPVersion(major: 8, minor: 5)

    private static func sampleModel(_ sample: Sample) -> AppModel {
        let home = "/Users/you/Paddock"
        let sites = [
            Site(name: "blog", path: "\(home)/blog", kind: .parked, secured: true, php: v85, pinned: false),
            Site(name: "shop", path: "\(home)/shop", kind: .parked, secured: false, php: v84, pinned: true),
            Site(name: "wiki", path: "\(home)/wiki", kind: .parked, secured: false, php: v85, pinned: false),
        ]
        let status: EngineStatus?
        switch sample {
        case .running, .blocked:
            let blocked = sample == .blocked
                ? [80, 443].map { PortHolder(port: $0, pid: 123, command: "nginx", ownedByCurrentUser: true,
                                             executablePath: "/Applications/Other.app/Contents/Resources/nginx") }
                : []
            status = EngineStatus(running: sample == .running, blockedBy: blocked, portsNotPermitted: [],
                                  sites: sites, installedPHP: [v84, v85], defaultPHP: v85, processes: [:],
                                  resolverInstalled: true, trustEnabled: true, dnsRunning: true)
        case .stopped:
            status = nil
        }
        let model = AppModel(client: SampleClient(status: status),
                             services: SampleServices(parked: [home]),
                             quitter: SampleQuitter(),
                             availablePHP: (1...5).map { PHPVersion(major: 8, minor: $0) })
        model.status = status
        // Show one install in progress on the PHP tab.
        if sample == .running { model.busy = [AppModel.busyKey(.installPHP(version: PHPVersion(major: 8, minor: 3)))] }
        return model
    }

    private struct SampleClient: ClientProtocol {
        let status: EngineStatus?
        func send(_ r: Request, timeout: TimeInterval) throws -> Response {
            guard let status else { throw ClientError.daemonNotRunning }
            return .ok(status)
        }
    }

    private struct SampleServices: AppServices {
        let parked: [String]
        var isSystemIntegrationEnabled: Bool { true }
        var startsAtLogin: Bool { true }
        var isShellConfigured: Bool { false }
        func startDaemon() throws -> DaemonLauncher.Outcome { .viaSystem }
        func stopDaemon() throws {}
        func setStartsAtLogin(_ on: Bool) throws {}
        func restorePreviousSetup() throws -> [String] { [] }
        func configureShell() throws {}
        func parkedFolders() -> [String] { parked }
    }

    private struct SampleQuitter: ApplicationQuitter {
        func canQuit(appBundlePath: String) -> Bool { true }
        func quit(appBundlePath: String) -> Bool { false }
    }
}
