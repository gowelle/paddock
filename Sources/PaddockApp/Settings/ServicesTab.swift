import PaddockCore
import SwiftUI

/// The services Paddock runs (databases, cache, search, mail) and `Add Service…`. Plain; the model holds the logic.
struct ServicesTab: View {
    @EnvironmentObject private var model: AppModel
    /// The service whose `Create Database…` sheet is open.
    @SwiftUI.State private var databaseFor: String?
    @SwiftUI.State private var databaseName = ""

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
            SettingsFooter().padding(.horizontal, -20).padding(.bottom, -12)
        }
        .padding(20)
        .task { await model.loadCatalog() }
        .confirmationDialog(model.deleteDataQuestion ?? "", isPresented: Binding(
            get: { model.deleteDataQuestion != nil },
            // Cancel says so itself: a dismissal after the destructive button must not withdraw its confirmation.
            set: { _ in })) {
            Button("Remove and Delete Data", role: .destructive) {
                if let id = model.dataDeletionAsked { Task { await model.removeService(id, deleteData: true) } }
            }
            Button("Cancel", role: .cancel) { model.cancelRemoveAndDeleteData() }
        }
        .sheet(isPresented: Binding(get: { databaseFor != nil }, set: { if !$0 { databaseFor = nil } })) {
            createDatabaseSheet
        }
    }

    private var addMenu: some View {
        Menu("Add Service…") {
            ForEach(model.catalog) { entry in
                Button {
                    Task { await model.addService(kind: entry.kind, version: entry.version) }
                } label: {
                    Text(verbatim: "\(entry.title) (\(entry.licence))")
                }
                .disabled(entry.isAdding)
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
}

/// One service: name, state and ports, its notes, and its actions.
struct ServiceRowView: View {
    @EnvironmentObject private var model: AppModel
    let row: ServiceRow
    let createDatabase: () -> Void

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
                Button("Restart") { Task { await model.restartService(row.id) } }
                    .disabled(!row.canStop)
                Button("Copy .env") { Task { await model.copyEnv(row.id) } }
                if row.canOpen {
                    Button("Open") { model.openService(row.id) }
                }
                if row.canCreateDatabase {
                    Button("Create Database…", action: createDatabase)
                }
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
         .serviceRemove(name: row.id, deleteData: false), .serviceRemove(name: row.id, deleteData: true)]
            .contains(where: model.isBusy)
    }
}
