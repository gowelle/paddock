import AppKit
import PaddockCore
import SwiftUI

struct SitesTab: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var health = SiteHealthModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Table(model.sites) {
                TableColumn("Site") { site in
                    Link(site.host, destination: URL(string: site.url) ?? URL(fileURLWithPath: site.path))
                        .foregroundStyle(Theme.honeyText)
                }
                TableColumn("Health") { site in
                    SiteHealthBadge(health: health.entries[site.name])
                }
                .width(120)
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
                TableColumn("PHP") { site in phpPicker(site) }
                    .width(140)
            }
            .tableSurface()

            if model.sites.isEmpty {
                TableCaption("No sites yet. Put a project folder in your sites folder and it appears here.")
            }
            if let notice = model.trustNotice {
                TableCaption(notice)
            }
            SettingsFooter().padding(.horizontal, -20).padding(.bottom, -12)
        }
        .padding(20)
        .onAppear { health.refresh(sites: model.sites, isServing: model.isServing) }
        .onChange(of: model.sites) { sites in
            health.refresh(sites: sites, isServing: model.isServing)
        }
        .onChange(of: model.isServing) { isServing in
            health.refresh(sites: model.sites, isServing: isServing)
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            health.refresh(sites: model.sites, isServing: model.isServing)
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
