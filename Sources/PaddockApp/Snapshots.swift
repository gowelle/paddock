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
            ("settings-general", AnyView(GeneralTab().settingsTheme().environmentObject(running)), SettingsView.size),
            ("settings-php", AnyView(PHPTab().settingsTheme().environmentObject(running)), SettingsView.size),
            ("settings-sites", AnyView(SitesTab().settingsTheme().environmentObject(running)), SettingsView.size),
            ("settings-services-none", AnyView(ServicesTab().settingsTheme().environmentObject(running)), SettingsView.size),
            ("settings-services", AnyView(ServicesTab().settingsTheme().environmentObject(servicesModel(adding: false))),
             SettingsView.size),
            ("settings-services-adding", AnyView(ServicesTab().settingsTheme().environmentObject(servicesModel(adding: true))),
             SettingsView.size),
            ("settings-tasks-running", AnyView(TasksTab().settingsTheme().environmentObject(tasksModel(.running))),
             SettingsView.size),
            ("settings-tasks-needs-approval", AnyView(TasksTab().settingsTheme().environmentObject(tasksModel(.needsApproval))),
             SettingsView.size),
            ("approval-sheet", AnyView(ApprovalSheet().environmentObject(approvalModel())), nil),
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
            status = EngineStatus(running: sample == .running, blockedBy: blocked,
                                  sites: sites, installedPHP: [v84, v85], defaultPHP: v85, processes: [:],
                                  resolverInstalled: true, trustEnabled: true, dnsRunning: true,
                                  portHelperInstalled: true)
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

    // MARK: Services and site tasks

    private static func runningStatus(sites: [Site], services: [ServiceStatus] = []) -> EngineStatus {
        EngineStatus(running: true, blockedBy: [], sites: sites, installedPHP: [v84, v85], defaultPHP: v85, processes: [:],
                     resolverInstalled: true, trustEnabled: true, dnsRunning: true, portHelperInstalled: true,
                     services: services)
    }

    private static func model(_ status: EngineStatus, catalog: [CatalogEntry] = []) -> AppModel {
        let model = AppModel(client: SampleClient(status: status, catalog: catalog),
                             services: SampleServices(parked: ["/Users/you/Paddock"]), quitter: SampleQuitter())
        model.status = status
        return model
    }

    /// Runs `work` to the end (the sample client answers at once) before the view is rendered.
    private static func settle(_ work: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in
            await work()
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func service(_ id: String, _ name: String, kind: String, state: ServiceState, ports: [String: Int],
                                openURL: String? = nil, notes: [String]? = nil) -> ServiceStatus {
        ServiceStatus(id: id, name: name, kind: kind, version: "1", displayName: name, state: state, ports: ports,
                      env: [], openURL: openURL, dataPath: "/Users/you/Library/Application Support/Paddock/services/\(id)/data",
                      autostart: true, mainPort: ports["main"] ?? ports["smtp"], notes: notes)
    }

    /// Three services in mixed states (running with a note, stopped, port in use); with `adding`, PostgreSQL 17 is
    /// being added.
    private static func servicesModel(adding: Bool) -> AppModel {
        let services = [
            service("meilisearch-1-57", "Meilisearch 1.57", kind: "meilisearch", state: .running, ports: ["main": 7701],
                    openURL: "http://127.0.0.1:7701",
                    notes: ["Search indexes are tied to Meilisearch 1.57; export a dump before changing version."]),
            service("postgres-18", "PostgreSQL 18", kind: "postgres", state: .stopped, ports: ["main": 5433]),
            service("mail", "Mail", kind: "mail", state: .portInUse(holder: "Herd"), ports: ["smtp": 1025, "http": 8025],
                    openURL: "http://127.0.0.1:8025"),
        ]
        let catalog = [
            CatalogEntry(kind: "postgres", displayName: "PostgreSQL", licence: "PostgreSQL", versions: ["18.7.0", "17.12.0"],
                         downloadBytes: nil,
                         series: [CatalogSeries(series: "18", version: "18.7.0", downloadBytes: nil, needsDownload: false),
                                  CatalogSeries(series: "17", version: "17.12.0", downloadBytes: nil, needsDownload: true)]),
        ]
        let model = model(runningStatus(sites: [], services: services), catalog: catalog)
        settle { await model.loadCatalog() }
        if adding { model.busy = [AppModel.busyKey(.serviceAdd(kind: "postgres", version: "17"))] }
        return model
    }

    enum TasksSample { case running, needsApproval }

    private static let shopPath = "/Users/you/Code/shop"

    private static func task(_ name: String, _ run: String, _ state: TaskState, restartOnChange: Bool = true,
                             warning: String? = nil) -> TaskStatus {
        TaskStatus(name: name, run: run, state: state, restartOnChange: restartOnChange,
                   logPath: "/Users/you/Library/Application Support/Paddock/log/tasks/shop/\(name).log", warning: warning)
    }

    /// Running tasks (one crashed, one with the listening warning) with forwarding; or a site waiting for approval.
    private static func tasksModel(_ sample: TasksSample) -> AppModel {
        let shop: SiteTasksStatus
        switch sample {
        case .running:
            shop = SiteTasksStatus(
                approval: .approved,
                tasks: [task("queue", "php artisan queue:work --tries=3", .running(pid: 4182)),
                        task("scheduler", "php artisan schedule:work",
                             .crashed(reason: Messages.taskRestarting(status: 1))),
                        task("reverb", "php artisan reverb:start --host=0.0.0.0 --port=8080", .running(pid: 4190),
                             restartOnChange: false,
                             warning: Messages.listening(ListeningAddress(host: "0.0.0.0", port: 8080)))],
                pending: [], pendingHash: nil, notice: nil, routes: ["/app": 8080, "/apps": 8080])
        case .needsApproval:
            shop = approvalStatus()
        }
        let sites = [
            Site(name: "shop", path: shopPath, kind: .parked, secured: true, php: v85, pinned: false, tasks: shop),
            Site(name: "blog", path: "/Users/you/Code/blog", kind: .parked, secured: true, php: v85, pinned: false),
        ]
        return model(runningStatus(sites: sites))
    }

    /// Four commands (one 300 characters long) and two forwarding lines, waiting for approval.
    private static func approvalStatus() -> SiteTasksStatus {
        let long = "php artisan queue:work redis --queue=payments,notifications,emails,default --tries=5 --backoff=10 "
            + "--timeout=120 --sleep=2 --max-jobs=1000 --max-time=3600 --memory=512 --rest=1 --name=shop-worker "
            + "--env=local --force --verbose --no-interaction --quiet-on-empty --stop-when-empty-after=600 --extra=12345"
        let commands = [("flutterwave", "php artisan flutterwave:forward --port=8081"),
                        ("queue", long),
                        ("reverb", "php artisan reverb:start --host=127.0.0.1 --port=8080"),
                        ("scheduler", "php artisan schedule:work")]
        let pending = commands.map { PendingTask(name: $0.0, run: $0.1, port: nil) }
            + [PendingTask(name: "/app", run: nil, port: 8080), PendingTask(name: "/apps", run: nil, port: 8080)]
        return SiteTasksStatus(approval: .needsApproval,
                               tasks: commands.map { task($0.0, $0.1, .waitingForApproval) },
                               pending: pending, pendingHash: "v1:sample", notice: nil)
    }

    private static func approvalModel() -> AppModel {
        let site = Site(name: "shop", path: shopPath, kind: .parked, secured: true, php: v85, pinned: false,
                        tasks: approvalStatus())
        let model = model(runningStatus(sites: [site]))
        settle { await model.showApproval(site: "shop") }
        return model
    }

    private struct SampleClient: ClientProtocol {
        let status: EngineStatus?
        var catalog: [CatalogEntry] = []
        func send(_ r: Request, timeout: TimeInterval) throws -> Response {
            guard let status else { throw ClientError.daemonNotRunning }
            if r == .serviceCatalog { return .catalog(catalog) }
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
        func checkMayChangeSystem() throws {}
    }

    private struct SampleQuitter: ApplicationQuitter {
        func canQuit(appBundlePath: String) -> Bool { true }
        func quit(appBundlePath: String) -> Bool { false }
    }
}
