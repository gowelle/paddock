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
        let noMail = MailModel(client: SampleMail(), services: { [] })
        let noDatabases = DatabasesModel(browser: nil, services: { [] })
        let menuDatabases = databasesMenuModel()
        let shots: [(String, AnyView, CGSize?)] = [
            ("menu-running", AnyView(MenuContentView().environmentObject(running).environmentObject(noMail)
                .environmentObject(menuDatabases)), nil),
            ("menu-blocked", AnyView(MenuContentView().environmentObject(sampleModel(.blocked))
                .environmentObject(noMail).environmentObject(menuDatabases)), nil),
            ("menu-stopped", AnyView(MenuContentView().environmentObject(sampleModel(.stopped))
                .environmentObject(noMail).environmentObject(menuDatabases)), nil),
            ("settings-general", AnyView(GeneralTab().settingsTheme().environmentObject(running)), SettingsView.size),
            ("settings-php", AnyView(PHPTab().settingsTheme().environmentObject(running)), SettingsView.size),
            ("settings-sites", AnyView(SitesTab().settingsTheme().environmentObject(running)), SettingsView.size),
            ("settings-sites-empty", AnyView(SitesTab().settingsTheme().environmentObject(sampleModel(.stopped))), SettingsView.size),
            ("doctor", AnyView(DoctorView().environmentObject(doctorModel(problems: false))),
             DoctorView.size),
            ("doctor-problems", AnyView(DoctorView().environmentObject(doctorModel(problems: true))),
             DoctorView.size),
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
            ("approval-sheet-nothing", AnyView(ApprovalSheet().environmentObject(approvalModel(nothing: true))), nil),
            ("menu-mail", AnyView(MenuContentView().environmentObject(running).environmentObject(mailModel(reading: nil))
                .environmentObject(menuDatabases)), nil),
            ("mail-list", AnyView(MailView().environmentObject(running).environmentObject(mailModel(reading: nil))),
             MailView.size),
            ("mail-text", AnyView(MailView().environmentObject(running).environmentObject(mailModel(reading: .text))),
             MailView.size),
            ("mail-source", AnyView(MailView().environmentObject(running).environmentObject(mailModel(reading: .source))),
             MailView.size),
            ("mail-no-match", AnyView(MailView().environmentObject(running).environmentObject(mailModel(searching: "invoice"))),
             MailView.size),
            ("dumps", AnyView(DumpList(model: dumpsModel())), DumpsView.size),
            ("about", AnyView(AboutView()), nil),
            ("licence", AnyView(LicenseAcceptanceView(onAccept: {}, onDecline: {})), nil),
            ("logs", AnyView(LogsView().environmentObject(running).environmentObject(logsModel(filter: ""))), LogsView.size),
            ("logs-filtered", AnyView(LogsView().environmentObject(running).environmentObject(logsModel(filter: "payment"))),
             LogsView.size),
            ("logs-none", AnyView(LogsView().environmentObject(running).environmentObject(LogsModel(find: { [] }))), LogsView.size),
            ("mail-none", AnyView(MailView().environmentObject(running).environmentObject(noMail)), MailView.size),
            ("databases", AnyView(DatabasesView().environmentObject(running).environmentObject(databasesModel())),
             DatabasesView.size),
            ("databases-query", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(querying: true))), DatabasesView.size),
            ("databases-search", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(searching: "ada"))), DatabasesView.size),
            ("databases-no-match", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(searching: "zzz"))), DatabasesView.size),
            ("databases-edit", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(editing: 1))), DatabasesView.size),
            ("databases-new", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(inserting: true))), DatabasesView.size),
            ("databases-readonly", AnyView(DatabasesView().environmentObject(running)
                .environmentObject(databasesModel(readOnly: true))), DatabasesView.size),
            ("databases-json", AnyView(JSONInspector(text: """
            {
              "digest" : "weekly",
              "fields" : [
                "orders",
                "stock"
              ],
              "theme" : "dark"
            }
            """)), CGSize(width: 520, height: 320)),
            ("databases-none", AnyView(DatabasesView().environmentObject(running).environmentObject(noDatabases)),
             DatabasesView.size),
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
                                  portHelperInstalled: true, xdebug: [v84], xdebugAvailable: [v84, v85])
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

    // MARK: - Doctor

    /// A healthy secured site, or a report with a failed HTTP row, without touching the network.
    private static func doctorModel(problems: Bool) -> DoctorModel {
        let php = PHPVersion(major: 8, minor: 5)
        let site = Site(name: "shop", path: "/Users/you/Sites/shop", kind: .parked, secured: true,
                        php: php, pinned: false)
        let status = EngineStatus(running: true, blockedBy: [], sites: [site], installedPHP: [php],
                                  defaultPHP: php,
                                  processes: ["caddy": "running (pid 1)", "php-fpm-8.5": "running (pid 2)"],
                                  resolverInstalled: true, trustEnabled: true, dnsRunning: true,
                                  portHelperInstalled: true)
        let passed = { (id: String, title: String, detail: String) in
            DoctorCheck(id: id, title: title, outcome: .passed, detail: detail)
        }
        let report = DoctorReport(global: [
            passed("daemon", "The daemon answers (build 24)", "The daemon answers (build 24)."),
            passed("ports", "Ports 80 and 443 are free",
                   "Nothing was listening on 80 or 443 before Paddock."),
            passed("port-helper", "The port helper manages 80 and 443", "The port helper manages 80 and 443."),
            passed("resolver", "The .test resolver entry is installed", "The .test resolver entry is installed."),
            passed("dns", "DNS answers shop.test", "shop.test resolves to 127.0.0.1."),
            passed("caddy", "Caddy is running", "Caddy is running."),
        ], sites: [
            .init(site: "shop", host: "shop.test", php: php, url: "https://shop.test", checks: [
                passed("php", "PHP 8.5 is installed", "PHP 8.5 is installed."),
                passed("php-fpm", "PHP-FPM 8.5 is running", "PHP-FPM 8.5 is running."),
                passed("folder", "The site folder is readable", "/Users/you/Sites/shop can be read."),
                passed("trust", "macOS trusts Paddock's certificate", "macOS trusts Paddock's certificate."),
                problems
                    ? DoctorCheck(id: "http", title: "https://shop.test answers", outcome: .failed,
                                  detail: "HTTPS 500 in 30 ms. Some request reached the site and failed; "
                                      + "see the site's log.")
                    : passed("http", "https://shop.test answers", "HTTPS 200 in 24 ms."),
                DoctorCheck(id: "log", title: "Newest error in the site's log", outcome: .info,
                            detail: "No errors in laravel.log."),
            ]),
        ])
        let model = DoctorModel(fetchStatus: { status }, diagnose: { _, _ in report })
        model.target = "shop"
        settle { await model.check() }
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

    // MARK: - Dumps

    /// The window's contents without its listening (a snapshot opens no port): two dumps as they would arrive.
    private struct DumpList: View {
        @ObservedObject var model: DumpsModel
        var body: some View { DumpsView(listens: false).environmentObject(model) }
    }

    private static func dumpsModel() -> DumpsModel {
        final class Quiet: DumpListening {
            func start() throws {}
            func stop() {}
        }
        let model = DumpsModel(listener: { _, _ in Quiet() }, route: { _ in })
        func node(_ id: Int, _ kind: DumpNode.Kind, _ head: String, _ children: [DumpNode] = [], tail: String? = nil) -> DumpNode {
            DumpNode(id: id, kind: kind, head: head, body: [], children: children, tail: tail)
        }
        let order = node(1, .hash, "App\\Models\\Order {#1423", [
            node(2, .scalar, "+id: 1042"),
            node(3, .string, "+status: \"shipped\""),
            node(4, .hash, "#lines: array:2 [", [node(5, .scalar, "\"widget\" => 2"), node(6, .scalar, "\"gadget\" => 1")], tail: "]"),
            node(7, .scalar, "-total: 59.0"),
            node(8, .hash, "+customer: App\\Models\\User {#1388", [node(9, .string, "+name: \"Ada\"")], tail: "}"),
        ], tail: "}")
        let queued = node(1, .hash, "array:2 [", [node(2, .scalar, "\"queued\" => 3"), node(3, .string, "\"queue\" => \"default\"")], tail: "]")
        let at = Date(timeIntervalSince1970: 1_795_310_050)
        settle {
            await model.open()
            model.received(.success(Dump(id: 0, time: at.addingTimeInterval(-20), origin: "artisan queue:work --tries=3",
                                         file: "/Users/you/Paddock/shop/app/Jobs/Worker.php", line: 9, root: queued)))
            model.received(.success(Dump(id: 0, time: at, origin: "GET https://shop.test/orders/1042",
                                         file: "/Users/you/Paddock/shop/app/Http/Controllers/OrderController.php", line: 42,
                                         root: order)))
        }
        return model
    }

    // MARK: - Logs

    /// A few logs, with a site's Laravel log on show: an error (its trace unfolded), a warning and ordinary lines.
    private static func logsModel(filter: String) -> LogsModel {
        let folder = "/Users/you/Library/Application Support/Paddock/log"
        let site = "/Users/you/Paddock/shop/storage/logs"
        let laravel = LogSource(title: "laravel.log", url: URL(fileURLWithPath: "\(site)/laravel.log"))
        let sections = [
            LogSection(title: "Paddock", sources: [
                LogSource(title: "Paddock", url: URL(fileURLWithPath: "\(folder)/paddockd.log")),
                LogSource(title: "Web server", url: URL(fileURLWithPath: "\(folder)/caddy.log")),
            ]),
            LogSection(title: "PHP", sources: [
                LogSource(title: "PHP 8.5 errors", url: URL(fileURLWithPath: "\(folder)/php-8.5.log")),
                LogSource(title: "PHP-FPM 8.5", url: URL(fileURLWithPath: "\(folder)/php-fpm-8.5.log")),
            ]),
            LogSection(title: "Services", sources: [
                LogSource(title: "PostgreSQL 18", url: URL(fileURLWithPath: "\(folder)/service-postgres-18.log")),
                LogSource(title: "Mail", url: URL(fileURLWithPath: "\(folder)/service-mail.log")),
            ]),
            LogSection(title: "shop: tasks", sources: [
                LogSource(title: "queue", url: URL(fileURLWithPath: "\(folder)/tasks/shop/queue.log")),
                LogSource(title: "scheduler", url: URL(fileURLWithPath: "\(folder)/tasks/shop/scheduler.log")),
            ]),
            LogSection(title: "shop: logs", sources: [
                laravel,
                LogSource(title: "payments.log", url: URL(fileURLWithPath: "\(site)/payments.log")),
            ]),
        ]
        let lines = [
            "[2026-11-22 10:14:02] local.INFO: Order 1042 placed {\"user\":7}",
            "[2026-11-22 10:14:03] local.INFO: Payment authorised for order 1042",
            "[2026-11-22 10:14:05] local.WARNING: Payment gateway answered slowly (2.4s)",
            "[2026-11-22 10:14:09] local.ERROR: Call to undefined method App\\Models\\Order::ship() {\"exception\":\"[object] (Error(code: 0))",
            "[stacktrace]",
            "#0 /Users/you/Paddock/shop/app/Http/Controllers/OrderController.php(42): App\\Services\\Shipping->dispatch()",
            "#1 /Users/you/Paddock/shop/vendor/laravel/framework/src/Illuminate/Routing/Controller.php(54): ...",
            "#2 {main}",
            "[2026-11-22 10:14:10] local.INFO: Mail queued: Your order #1042 has shipped",
            "[2026-11-22 10:14:12] local.DEBUG: select * from \"orders\" where \"id\" = 1042 limit 1",
        ]
        let model = LogsModel(find: { sections }, read: { url, position in
            guard position == nil else { return LogChunk(lines: [], position: position, restarted: false) }
            return LogChunk(lines: url == laravel.url ? lines : [], position: LogPosition(offset: 1, file: 1), restarted: true)
        })
        settle {
            model.refreshSections()
            await model.select(laravel.id)
            if let error = model.entries.first(where: \.isProblem) { model.toggle(error) }
            model.setFilter(filter)
        }
        return model
    }

    // MARK: - Mail

    /// A mail service with three caught messages; with `reading`, the first is open and shown that way. (The
    /// HTML view is a web view, which an off-screen capture can't draw, so the shots show text and source.)
    private static func mailModel(searching text: String) -> MailModel {
        let model = mailModel(reading: nil)
        settle { await model.search(for: text) }
        return model
    }

    private static func mailModel(reading: MailBody?) -> MailModel {
        let mail = service("mail", "Mail", kind: "mail", state: .running, ports: ["smtp": 1025, "http": 8025],
                           openURL: "http://127.0.0.1:8025")
        let model = MailModel(client: SampleMail(), services: { [mail] })
        settle {
            await model.refresh()
            if let reading {
                await model.select("a")
                await model.show(reading)
            }
        }
        return model
    }

    private struct SampleMail: MailClient {
        static let shop = MailAddress(name: "Paddock Shop", address: "orders@shop.test")
        static let ada = MailAddress(name: "Ada Customer", address: "ada@example.test")
        static let sent = Date(timeIntervalSince1970: 1_795_310_050)

        func inbox(at base: URL, limit: Int) async throws -> MailInbox {
            MailInbox(total: 3, unread: 2, messages: [
                MailSummary(id: "a", read: false, from: Self.shop, to: [Self.ada], subject: "Your order #1042 has shipped",
                            created: Self.sent, attachments: 1,
                            snippet: "Hello Ada, your order #1042 has shipped and is on its way."),
                MailSummary(id: "b", read: false, from: MailAddress(address: "no-reply@blog.test"), to: [Self.ada],
                            subject: "Reset your password", created: Self.sent.addingTimeInterval(-900),
                            snippet: "Someone asked to reset the password for your account."),
                MailSummary(id: "c", read: true, from: MailAddress(name: "Wiki", address: "wiki@wiki.test"), to: [Self.ada],
                            subject: "Weekly digest", created: Self.sent.addingTimeInterval(-90_000),
                            snippet: "Four pages changed this week."),
            ])
        }

        func message(at base: URL, id: String) async throws -> MailMessage {
            MailMessage(id: id, from: Self.shop, to: [Self.ada, MailAddress(address: "ops@shop.test")],
                        cc: [MailAddress(address: "accounts@shop.test")], subject: "Your order #1042 has shipped",
                        date: Self.sent,
                        text: "Hello Ada,\n\nYour order #1042 has shipped.\n\nThanks,\nPaddock Shop\n",
                        html: "<h1>Your order has shipped</h1>",
                        attachments: [MailPart(partID: "2", fileName: "invoice-1042.csv", contentType: "text/csv", size: 23)])
        }

        func source(at base: URL, id: String) async throws -> String {
            """
            Return-Path: <orders@shop.test>
            From: Paddock Shop <orders@shop.test>
            To: Ada Customer <ada@example.test>, ops@shop.test
            Cc: accounts@shop.test
            Subject: Your order #1042 has shipped
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="===============1042=="

            --===============1042==
            Content-Type: text/plain; charset="utf-8"

            Hello Ada,

            Your order #1042 has shipped.
            """
        }

        func part(at base: URL, messageID: String, partID: String) async throws -> Data { Data() }

        func search(at base: URL, query: String, limit: Int) async throws -> MailInbox {
            MailInbox(total: 3, unread: 2, messages: [])
        }

        func delete(at base: URL, ids: [String]) async throws {}

        func setRead(at base: URL, ids: [String], read: Bool) async throws {}
    }

    // MARK: - Databases

    /// A running PostgreSQL with a shop database, its tables on the left and users' rows on show. With
    /// `querying`, the SQL console has run a count as well; with `searching`, the rows are narrowed to it.
    /// With `editing`, that row is open for editing; with `inserting`, a new row is being added; with
    /// `readOnly`, the view (no primary key) is on show instead.
    private static func databasesModel(searching: String? = nil, querying: Bool = false,
                                       editing: Int? = nil, inserting: Bool = false,
                                       readOnly: Bool = false) -> DatabasesModel {
        let postgres = service("postgres-18", "PostgreSQL 18", kind: "postgres", state: .running, ports: ["main": 5432])
        let model = DatabasesModel(browser: SampleDatabase(), services: { [postgres] })
        settle {
            await model.refresh()
            if readOnly {
                await model.select(table: DatabaseTable(schema: "public", name: "recent_orders", kind: "view"))
            } else {
                await model.select(table: DatabaseTable(schema: "public", name: "users", kind: "table"))
                if let searching {
                    model.setRowSearch(searching)
                    // The model collects typing for a moment before reading; let that moment pass.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                if querying {
                    model.setQuery("SELECT count(*) FROM users")
                    await model.runQuery()
                }
                if let editing {
                    await model.beginEdit(row: editing)
                }
                if inserting {
                    model.beginInsert()
                }
            }
        }
        return model
    }

    /// Only enough for the menu to offer the Databases window.
    private static func databasesMenuModel() -> DatabasesModel {
        let postgres = service("postgres-18", "PostgreSQL 18", kind: "postgres", state: .running, ports: ["main": 5432])
        let model = DatabasesModel(browser: nil, services: { [postgres] })
        settle { await model.refresh() }
        return model
    }

    private struct SampleDatabase: DatabaseBrowsing, DatabaseWriting {
        static let users = DatabaseTable(schema: "public", name: "users", kind: "table")
        static let userColumns = ["id", "name", "meta", "email", "created_at"]
        static let userRows: [[String?]] = [
            ["1", "Ada Lovelace", #"{"theme":"dark","digest":"weekly"}"#, "ada@example.test",
             "2026-11-18 12:01:44"],
            ["2", "Grace Hopper", #"{"theme":"light","digest":"never"}"#, "grace@example.test",
             "2026-11-18 12:04:10"],
            ["3", "Alan Turing", nil, "alan@example.test", "2026-11-19 08:31:55"],
            ["4", "Katherine Johnson", #"{"theme":"dark","fields":["orders","stock"]}"#,
             "katherine@example.test", "2026-11-19 09:12:38"],
            ["5", "Edsger Dijkstra", nil, "edsger@example.test", "2026-11-20 11:20:01"],
        ]

        func databases(for service: DatabaseService) throws -> [String] { ["postgres", "shop"] }

        func tables(for service: DatabaseService, database: String) throws -> [DatabaseTable] {
            [Self.users,
             DatabaseTable(schema: "public", name: "orders", kind: "table"),
             DatabaseTable(schema: "public", name: "order_items", kind: "table"),
             DatabaseTable(schema: "public", name: "recent_orders", kind: "view"),
             DatabaseTable(schema: "public", name: "sessions", kind: "table")]
        }

        func columns(for service: DatabaseService, database: String, table: DatabaseTable) throws -> [DatabaseColumn] {
            if table.name == "recent_orders" {
                return [DatabaseColumn(name: "order_id", type: "bigint", nullable: false,
                                       defaultValue: nil, primary: false),
                        DatabaseColumn(name: "total", type: "numeric", nullable: true,
                                       defaultValue: nil, primary: false)]
            }
            return [DatabaseColumn(name: "id", type: "bigint", nullable: false, defaultValue: nil,
                                   primary: true, identity: true),
                    DatabaseColumn(name: "name", type: "varchar(255)", nullable: false,
                                   defaultValue: nil, primary: false),
                    DatabaseColumn(name: "meta", type: "jsonb", nullable: true, defaultValue: nil, primary: false),
                    DatabaseColumn(name: "email", type: "varchar(255)", nullable: false,
                                   defaultValue: nil, primary: false),
                    DatabaseColumn(name: "created_at", type: "timestamptz", nullable: true,
                                   defaultValue: nil, primary: false)]
        }

        func rows(for service: DatabaseService, database: String, table: DatabaseTable,
                  search: String?, limit: Int) throws -> DatabaseRows {
            if table.name == "recent_orders" {
                return DatabaseRows(columns: ["order_id", "total"],
                                    rows: [["1042", "129.00"], ["1043", "54.50"]], truncated: false)
            }
            guard let search, !search.isEmpty else {
                return DatabaseRows(columns: Self.userColumns, rows: Self.userRows, truncated: true)
            }
            let matched = Self.userRows.filter { row in
                row.contains { ($0 ?? "").localizedCaseInsensitiveContains(search) }
            }
            return DatabaseRows(columns: Self.userColumns, rows: matched, truncated: false)
        }

        func query(for service: DatabaseService, database: String, sql: String, limit: Int) throws -> DatabaseRows {
            DatabaseRows(columns: ["count"], rows: [["1284"]], truncated: false)
        }

        func row(for service: DatabaseService, database: String, table: DatabaseTable,
                 key: [String: String?]) throws -> [String: String?] {
            let id = key["id"] ?? nil
            guard let row = Self.userRows.first(where: { ($0.first ?? nil) == id }) else { return key }
            return ["id": row[0], "name": row[1], "meta": row[2], "email": row[3], "created_at": row[4]]
        }

        func insert(for service: DatabaseService, database: String, table: DatabaseTable,
                    values: [String: String?]) throws {}

        func update(for service: DatabaseService, database: String, table: DatabaseTable,
                    key: [String: String?], changes: [String: String?],
                    expected: [String: String?]) throws {}

        func delete(for service: DatabaseService, database: String, table: DatabaseTable,
                    key: [String: String?], expected: [String: String?]) throws {}
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

    /// The sheet for a site with something to approve; with `nothing`, for one whose file went away.
    private static func approvalModel(nothing: Bool = false) -> AppModel {
        let gone = SiteTasksStatus(approval: .changed, tasks: [task("queue", "php artisan queue:work", .running(pid: 4182))],
                                   pending: [], pendingHash: nil, notice: Messages.tasksFileRemoved(site: "shop"))
        let site = Site(name: "shop", path: shopPath, kind: .parked, secured: true, php: v85, pinned: false,
                        tasks: nothing ? gone : approvalStatus())
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
