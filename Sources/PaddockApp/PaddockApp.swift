import AppKit
import PaddockCore
import SwiftUI

@main
enum Entry {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        Theme.registerFonts()
        if let index = arguments.firstIndex(of: "--snapshots") {
            let directory = arguments.count > index + 1 ? arguments[index + 1] : "dist/snapshots"
            exit(Snapshots.write(to: URL(fileURLWithPath: directory, isDirectory: true)) ? 0 : 1)
        }
        PaddockApp.main()
    }
}

struct PaddockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppDelegate.model
    @ObservedObject private var mail = AppDelegate.mail
    @ObservedObject private var logs = AppDelegate.logs
    @ObservedObject private var dumps = AppDelegate.dumps

    var body: some Scene {
        // Window style, so the menu's content is one plain SwiftUI view the snapshot tool can render too.
        MenuBarExtra("Paddock", systemImage: "pedestrian.gate.closed") {
            MenuContentView()
                .environmentObject(model)
                .environmentObject(mail)
        }
        .menuBarExtraStyle(.window)

        Window("Mail", id: MailView.windowID) {
            MailView()
                .environmentObject(model)
                .environmentObject(mail)
        }
        .defaultSize(MailView.size)

        Window("Logs", id: LogsView.windowID) {
            LogsView()
                .environmentObject(model)
                .environmentObject(logs)
        }
        .defaultSize(LogsView.size)

        Window("Dumps", id: DumpsView.windowID) {
            DumpsView()
                .environmentObject(dumps)
        }
        .defaultSize(DumpsView.size)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(logs)
        }

        Window("About Paddock", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

struct LicenseAcceptanceView: View {
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paddock License Agreement")
                .font(Theme.heading(22))
            Text("Review the license before using Paddock.")
                .foregroundStyle(Theme.inkMuted)
            ScrollView {
                Text(AboutView.license)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 380)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            HStack {
                Spacer()
                Button("Decline") {
                    onDecline()
                }
                Button("Accept") {
                    onAccept()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .foregroundStyle(Theme.ink)
        .tint(Theme.honeyText)
        .background(Theme.ground)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let licenseAcceptedKey = "PaddockLicenseAccepted-v1"

    static var isLicenseAccepted: Bool {
        UserDefaults.standard.bool(forKey: licenseAcceptedKey)
    }

    private var licenseWindow: NSWindow?
    static let model: AppModel = {
        let manifest = (try? PHPManifest.bundled())?.builds.map(\.version) ?? []
        return AppModel(client: PaddockClient(), services: LiveAppServices(), quitter: AppKitQuitter(),
                        availablePHP: Array(Set(manifest)), paths: .current,
                        copyText: Pasteboard.copy,
                        open: { NSWorkspace.shared.open($0) },
                        showLog: { log in Task { await logs.request(path: log.path) } })
    }()

    /// Listens for dumps while its window is open, and has the daemon tell PHP to send them here.
    static let dumps = DumpsModel(
        route: { port in
            await model.perform(.dumps(port: port))
            await model.refresh()
        },
        copy: { Pasteboard.copy($0, concealed: false) })

    /// Lists Paddock's logs and each site's own from the daemon's status, and reads the one on show.
    static let logs = LogsModel(find: { LogCatalog.sections(paths: .current, status: model.status) },
                                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })

    /// Checks for a newer Paddock once a day and when asked. Made at launch, so the daily check runs
    /// without the menu ever being opened.
    static let updates = Updates(preview: CommandLine.arguments.contains("--snapshots"))

    /// Reads the mail service wherever the daemon's status says it answers.
    static let mail = MailModel(client: HTTPMailClient(), services: { model.status?.services ?? [] })

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Self.updates
        if UserDefaults.standard.bool(forKey: Self.licenseAcceptedKey) {
            // Every accepted launch: start Paddock exactly as `paddock start` does.
            Task {
                await Self.model.launch()
                // A window that was open when the app last quit left PHP sending dumps to nobody.
                await Self.dumps.reconcile(daemonSendsTo: Self.model.status?.dumpsTo)
            }
        } else {
            showLicenseAcceptance()
        }
    }

    func showLicenseAcceptance() {
        if let licenseWindow, licenseWindow.isVisible {
            activateApp()
            licenseWindow.makeKeyAndOrderFront(nil)
            return
        }
        activateApp()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Paddock License Agreement"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(
            rootView: LicenseAcceptanceView(
                onAccept: { [weak self, weak window] in
                    guard let self else { return }
                    UserDefaults.standard.set(true, forKey: Self.licenseAcceptedKey)
                    window?.close()
                    self.licenseWindow = nil
                    Task { await Self.model.launch() }
                },
                onDecline: {
                    NSApplication.shared.terminate(nil)
                }
            )
        )
        licenseWindow = window
        window.makeKeyAndOrderFront(nil)
        activateApp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model.stopSendingDumps()
        Self.model.shutDownOwnedDaemon()
    }
}

/// Quits another application politely, as if the user chose Quit in it. Never sends a signal, and
/// only ever an application running for the current user.
struct AppKitQuitter: ApplicationQuitter {
    func canQuit(appBundlePath: String) -> Bool {
        application(at: appBundlePath) != nil
    }

    func quit(appBundlePath: String) -> Bool {
        application(at: appBundlePath)?.terminate() ?? false
    }

    private func application(at path: String) -> NSRunningApplication? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.first { app in
            guard let bundle = app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() else { return false }
            return bundle == wanted && Self.isOwnedByCurrentUser(app.processIdentifier)
        }
    }

    private static func isOwnedByCurrentUser(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_ucred.cr_uid == getuid()
    }
}

/// Brings this menu bar app forward, so a window it opens is not hidden behind other apps.
@MainActor
func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
}
