import PaddockCore
import SwiftUI

/// The services Paddock runs (databases, cache, search, mail) and `Add Service…`. Plain; the model holds the logic.
struct ServicesTab: View {
    @EnvironmentObject private var model: AppModel
    /// The service whose `Create Database…` sheet is open.
    @SwiftUI.State private var databaseFor: String?
    @SwiftUI.State private var databaseName = ""
    /// The service whose **Write to .env…** sheet is open, and the site it will write into.
    @SwiftUI.State private var envFor: String?
    @SwiftUI.State private var envSite: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                addMenu
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.catalog.filter(\.isAdding)) { entry in
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(verbatim: "Adding \(entry.title)…")
                            Spacer()
                        }
                        .padding(12)
                        Divider()
                    }
                    ForEach(model.serviceRows) { row in
                        ServiceRowView(row: row, createDatabase: {
                            databaseName = ""
                            databaseFor = row.id
                        }, writeEnv: {
                            envSite = model.sites.first?.name
                            envFor = row.id
                        })
                        Divider()
                    }
                    if model.serviceRows.isEmpty && !model.catalog.contains(where: \.isAdding) {
                        Caption("No services yet. Add a database, cache, search or mail service with Add Service…")
                            .padding(12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tableSurface()

            if let notice = model.serviceNotice {
                Caption(notice)
            }
            DismissibleErrorLine()
        }
        .padding(20)
        .task { await model.loadCatalog() }
        // Leaving the tab (or the window closing) withdraws an unanswered question.
        .onDisappear { model.cancelRemoveAndDeleteData() }
        // The buttons get the question as it was presented: hiding the dialog (before or after a button runs)
        // only hides it; Cancel and Escape cancel it, and confirming hands its token back.
        .confirmationDialog(model.dataDeletionRequest?.title ?? "", isPresented: Binding(
            get: { model.dataDeletionRequest != nil },
            set: { if !$0 { model.hideDataDeletionQuestion() } }),
            titleVisibility: .visible, presenting: model.dataDeletionRequest) { request in
            Button("Remove and Delete Data", role: .destructive) { model.confirmRemoveAndDeleteData(request) }
            Button("Cancel", role: .cancel) { model.cancelRemoveAndDeleteData() }
        } message: { request in
            Text(verbatim: request.message)
        }
        .sheet(isPresented: Binding(get: { databaseFor != nil }, set: { if !$0 { databaseFor = nil } })) {
            createDatabaseSheet
        }
        .sheet(isPresented: Binding(get: { envFor != nil }, set: { if !$0 { envFor = nil } })) {
            writeEnvSheet
        }
    }

    private var addMenu: some View {
        Menu("Add Service…") {
            ForEach(model.catalog) { entry in
                Button {
                    Task { await model.addService(kind: entry.kind, version: entry.version) }
                } label: {
                    Text(verbatim: "\(entry.title) (\(entry.licence))"
                         + (entry.unavailableReason.map { " \u{2014} \($0)" } ?? ""))
                }
                .disabled(entry.isAdding || entry.unavailableReason != nil)
            }
            if model.catalog.isEmpty {
                Text("No services available")
            }
        }
        .fixedSize()
    }

    private var createDatabaseSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Create a database in \(model.serviceRows.first { $0.id == databaseFor }?.name ?? "")")
                .font(.headline)
            TextField("Name", text: $databaseName)
                .textFieldStyle(.roundedBorder)
            Caption("Letters, numbers and underscores.")
            HStack {
                Spacer()
                Button("Cancel") { databaseFor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let id = databaseFor {
                        let name = databaseName
                        databaseFor = nil
                        Task { await model.createDatabase(in: id, named: name) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!AppModel.isValidDatabaseName(databaseName))
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var writeEnvSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Wire \(model.serviceRows.first { $0.id == envFor }?.name ?? "") into a site's .env")
                .font(.headline)
            if model.sites.isEmpty {
                Caption("No sites yet.")
            } else {
                Picker("Site", selection: $envSite) {
                    ForEach(model.sites) { site in
                        Text(verbatim: site.host).tag(Optional(site.name))
                    }
                }
                .fixedSize()
            }
            HStack {
                Spacer()
                Button("Cancel") { envFor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Write") {
                    guard let id = envFor, let name = envSite,
                          let site = model.sites.first(where: { $0.name == name }) else { return }
                    envFor = nil
                    Task { await model.writeEnv(id, into: site) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(envSite == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// One service: name, state and ports, its notes, and its actions.
struct ServiceRowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let row: ServiceRow
    let createDatabase: () -> Void
    let writeEnv: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.name).fontWeight(.semibold)
                Text(verbatim: row.stateText).foregroundStyle(Theme.inkMuted)
                Spacer()
                Text(verbatim: row.portText).foregroundStyle(Theme.inkMuted)
            }
            ForEach(row.notes, id: \.self) { Caption($0) }
            HStack(spacing: 6) {
                if row.canStop {
                    Button("Stop") { Task { await model.stopService(row.id) } }
                } else {
                    Button("Start") { Task { await model.startService(row.id) } }
                        .disabled(!row.canStart)
                }
                if let version = row.updateAvailable {
                    Button {
                        Task { await model.updateService(row.id) }
                    } label: {
                        if model.isBusy(.serviceUpdate(name: row.id)) {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(verbatim: "Updating…")
                            }
                        } else {
                            Text(verbatim: "Update to \(version)")
                        }
                    }
                    .help("Download \(row.name) \(version) and switch to it")
                }
                Button("Restart") { Task { await model.restartService(row.id) } }
                    .disabled(!row.canStop)
                Menu {
                    if row.canOpen {
                        Button("Open") {
                            if row.opensMailWindow {
                                activateApp()
                                openWindow(id: MailView.windowID)
                            } else {
                                model.openService(row.id)
                            }
                        }
                    }
                    Button("Open Log") { model.openServiceLog(row.id) }
                    Button("Copy .env") { Task { await model.copyEnv(row.id) } }
                    Button("Write to .env…", action: writeEnv)
                        .disabled(model.sites.isEmpty)
                    if row.canCreateDatabase {
                        Button("Create Database…", action: createDatabase)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for \(row.name)")
                .accessibilityLabel(Text("More actions for \(row.name)"))
                Spacer()
                Menu("Remove") {
                    Button("Remove (Keep Data)") { Task { await model.removeService(row.id, deleteData: false) } }
                    Button("Remove and Delete Data…") { model.askToRemoveAndDeleteData(row.id) }
                }
                .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(12)
    }

    private var isBusy: Bool {
        [Request.serviceStart(name: row.id), .serviceStop(name: row.id), .serviceRestart(name: row.id),
         .serviceRemove(name: row.id, deleteData: false), .serviceRemove(name: row.id, deleteData: true),
         .serviceEnv(id: row.id), .serviceUpdate(name: row.id)]
            .contains(where: model.isBusy)
    }
}

/// The error line at the foot of the Services and Tasks tabs, with a button to dismiss it (an error stays until
/// dismissed, replaced, or the same action succeeds).
struct DismissibleErrorLine: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let error = model.lastError {
            HStack(alignment: .firstTextBaseline) {
                VerbatimErrorText(text: error)
                Spacer()
                Button("Dismiss") { model.dismissError() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }
}

/// The quiet error line's look, with the text shown exactly as given (no Markdown, no localisation).
struct VerbatimErrorText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
