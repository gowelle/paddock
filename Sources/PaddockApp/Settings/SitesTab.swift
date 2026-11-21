import AppKit
import PaddockCore
import SwiftUI

struct SitesTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Table(model.sites) {
                TableColumn("Site") { site in
                    Link(site.host, destination: URL(string: site.url) ?? URL(fileURLWithPath: site.path))
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
                TableColumn("PHP") { site in phpPicker(site) }
                    .width(140)
            }

            if model.sites.isEmpty {
                Caption("No sites yet. Put a project folder in your sites folder and it appears here.")
            }
            if let notice = model.trustNotice {
                Caption(notice)
            }
            SettingsFooter().padding(.horizontal, -20).padding(.bottom, -12)
        }
        .padding(20)
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
