import AppKit
import PaddockCore
import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var model: AppModel
    @SwiftUI.State private var confirmingRestore = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Start Paddock at login", isOn: Binding(
                        get: { model.startsAtLogin },
                        set: { on in Task { await model.setStartsAtLogin(on) } }))
                        .disabled(!model.systemIntegrationEnabled)
                    if !model.systemIntegrationEnabled { Caption(AppModel.unavailableCaption) }
                }

                Section("Sites folders") {
                    ForEach(model.parked, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(Theme.inkMuted)
                            Text(Self.abbreviated(path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                Task { await model.perform(.forget(path: path)) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop serving this folder's sites")
                        }
                    }
                    Button("Add Folder…", action: addFolder)
                }

                if !model.shellConfigured {
                    Section {
                        Button("Add Paddock to Terminal") { Task { await model.addToTerminal() } }
                            .disabled(!model.systemIntegrationEnabled)
                        Caption(model.systemIntegrationEnabled
                                ? "Lets new Terminal windows use php, composer and paddock."
                                : AppModel.unavailableCaption)
                    }
                }

                Section {
                    Button("Restore Previous Setup…") { confirmingRestore = true }
                        .disabled(!model.systemIntegrationEnabled)
                    if !model.systemIntegrationEnabled {
                        Caption(AppModel.unavailableCaption)
                    } else if let message = model.restoreMessage {
                        Caption(message)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            SettingsFooter()
        }
        .alert("Restore your previous setup?", isPresented: $confirmingRestore) {
            Button("Restore", role: .destructive) { Task { await model.restorePreviousSetup() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paddock will stop serving sites and put your .test DNS setting back.")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.perform(.park(path: url.path)) }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Small secondary text under a control.
struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
