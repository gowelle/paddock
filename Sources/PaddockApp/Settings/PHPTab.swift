import AppKit
import PaddockCore
import SwiftUI

struct PHPTab: View {
    @EnvironmentObject private var model: AppModel
    @SwiftUI.State private var selection: PHPRow.ID?

    struct PHPRow: Identifiable {
        let version: PHPVersion
        var id: String { version.description }
    }

    private var rows: [PHPRow] { model.availablePHP.map(PHPRow.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Table(rows, selection: $selection) {
                TableColumn("Version") { row in Text("PHP \(row.version.description)") }
                TableColumn("") { row in stateText(row.version) }
                TableColumn("") { row in action(row.version) }
                    .width(90)
            }
            .tableSurface()

            HStack {
                Picker("Default", selection: Binding(
                    get: { model.defaultPHP },
                    set: { version in
                        if let version { Task { await model.perform(.use(version: version)) } }
                    })) {
                    ForEach(model.installedPHP, id: \.self) { version in
                        Text("PHP \(version.description)").tag(Optional(version))
                    }
                }
                .fixedSize()
                Spacer()
                Button("Open php.ini") {
                    if let ini = selectedIni { NSWorkspace.shared.open(ini) }
                }
                .disabled(selectedIni == nil)
            }
            SettingsFooter().padding(.horizontal, -20).padding(.bottom, -12)
        }
        .padding(20)
    }

    private var selectedVersion: PHPVersion? { selection.flatMap(PHPVersion.init) }

    private var selectedIni: URL? { selectedVersion.flatMap(model.phpIni) }

    @ViewBuilder
    private func stateText(_ version: PHPVersion) -> some View {
        if version == model.defaultPHP {
            Text("Default").foregroundStyle(Theme.honeyText)
        } else if model.installedPHP.contains(version) {
            Text("Installed").foregroundStyle(Theme.inkMuted)
        } else {
            Text("")
        }
    }

    @ViewBuilder
    private func action(_ version: PHPVersion) -> some View {
        if model.isBusy(.installPHP(version: version)) || model.isBusy(.removePHP(version: version)) {
            ProgressView().controlSize(.small)
        } else if model.installedPHP.contains(version) {
            Button("Remove") { Task { await model.perform(.removePHP(version: version)) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(version == model.defaultPHP)
        } else {
            Button("Install") { Task { await model.perform(.installPHP(version: version)) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
