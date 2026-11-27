import AppKit
import PaddockCore
import SwiftUI

struct SitesTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var doctor = AppDelegate.doctor
    @Environment(\.openWindow) private var openWindow
    @SwiftUI.State private var sharingSite: Site?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Toggle("Share sites on this network", isOn: Binding(
                    get: { model.status?.lan?.enabled ?? false },
                    set: { on in Task { await model.perform(.lan(enabled: on)) } }))
                    .disabled(model.status == nil || isChangingSharing)
                Spacer()
                if let url = model.lanURL {
                    Button("Copy Network Link") { model.copyLANLink(url) }
                        .buttonStyle(.link)
                }
            }
            if let lan = model.status?.lan, lan.enabled {
                Caption(Messages.lanSummary(lan)
                        + " Only the sites ticked below are reachable; services and databases stay private.")
            }

            Table(model.sites) {
                TableColumn("Site") { site in
                    Link(site.host, destination: URL(string: site.url) ?? URL(fileURLWithPath: site.path))
                        .foregroundStyle(Theme.honeyText)
                }
                TableColumn("Secure") { site in
                    Toggle("", isOn: Binding(
                        get: { site.secured },
                        set: { on in
                            Task { await model.perform(on ? .secure(site: site.name) : .unsecure(site: site.name)) }
                        }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .tint(Theme.pasture)
                        .disabled(model.isBusy(.secure(site: site.name)) || model.isBusy(.unsecure(site: site.name)))
                }
                .width(60)
                TableColumn("Network") { site in networkCell(site) }
                    .width(80)
                TableColumn("PHP") { site in phpPicker(site) }
                    .width(140)
                TableColumn("Check") { site in
                    Button("Check") {
                        doctor.target = site.name
                        openWindow(id: DoctorView.windowID)
                        Task { await doctor.check() }
                    }
                    .buttonStyle(.link)
                }
                .width(60)
            }
            .tableSurface()
            .popover(item: $sharingSite) { site in
                LANSharePopover(host: LAN.host(for: site.name),
                                url: model.lanURL(for: site) ?? "",
                                onCopy: {
                                    if let url = model.lanURL(for: site) { model.copyLANLink(url) }
                                })
            }

            if model.sites.isEmpty {
                TableCaption("No sites yet. Put a project folder in your sites folder and it appears here.")
            }
            if let notice = model.trustNotice {
                TableCaption(notice)
            }
            SettingsFooter().padding(.horizontal, -20).padding(.bottom, -12)
        }
        .padding(20)
    }

    private var isChangingSharing: Bool {
        model.isBusy(.lan(enabled: true)) || model.isBusy(.lan(enabled: false))
    }

    /// A checkbox shares the site, and a QR button appears once it is shared and sharing is on.
    private func networkCell(_ site: Site) -> some View {
        HStack(spacing: 2) {
            Toggle("", isOn: Binding(
                get: { site.lan },
                set: { on in Task { await model.perform(.lanSite(site: site.name, enabled: on)) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(Theme.pasture)
                .disabled(model.isBusy(.lanSite(site: site.name, enabled: true))
                          || model.isBusy(.lanSite(site: site.name, enabled: false)))
                .help("Share \(site.host) with devices on this network")
                .accessibilityLabel(Text("Share \(site.host) with devices on this network"))
            if site.lan, model.lanURL(for: site) != nil {
                Button { sharingSite = site } label: {
                    Image(systemName: "qrcode")
                }
                .buttonStyle(.borderless)
                .help("Show a QR code for \(LAN.host(for: site.name))")
                .accessibilityLabel(Text("Show a QR code for \(LAN.host(for: site.name))"))
            }
        }
    }

    /// `Default (<v>)` follows the default PHP; a version pins the site to it.
    private func phpPicker(_ site: Site) -> some View {
        Picker("", selection: Binding<PHPVersion?>(
            get: { site.pinned ? site.php : nil },
            set: { version in
                Task {
                    await model.perform(version.map { .isolate(site: site.name, version: $0) }
                                        ?? .unisolate(site: site.name))
                }
            })) {
            Text(model.defaultPHPLabel).tag(PHPVersion?.none)
            ForEach(model.installedPHP, id: \.self) { version in
                Text("PHP \(version.description)").tag(Optional(version))
            }
        }
        .labelsHidden()
    }
}
