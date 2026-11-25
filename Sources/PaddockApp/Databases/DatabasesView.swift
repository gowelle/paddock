import AppKit
import PaddockCore
import SwiftUI

/// The Databases window: services, databases and tables on the left; the chosen table's rows above the SQL
/// console. Plain; `DatabasesModel` holds the logic, and every read is read-only.
struct DatabasesView: View {
    static let windowID = "databases"
    static let size = CGSize(width: 1060, height: 680)

    @EnvironmentObject private var databases: DatabasesModel
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                DatabaseSidebar()
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 380, maxHeight: .infinity)
                VSplitView {
                    DatabaseTablePane()
                        .frame(minWidth: 520, minHeight: 220, maxHeight: .infinity)
                    DatabaseConsole()
                        .frame(minHeight: 150, idealHeight: 210, maxHeight: 380)
                }
            }
            if let error = databases.lastError {
                Rectangle().fill(Theme.line).frame(height: 1)
                ErrorLine(text: error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .foregroundStyle(Theme.ink)
        .tint(Theme.honeyText)
        .background(Theme.ground)
        // The service list comes from the daemon's status, so both are read while the window shows.
        .background(VisibilityReporter { visible in
            if visible {
                model.beginWatching()
                databases.beginWatching()
            } else {
                model.endWatching()
                databases.endWatching()
            }
        })
        // The destination rides with the dialog: dismissing it clears the pending one before these buttons'
        // tasks could read it.
        .alert("Discard the unsaved row?", isPresented: Binding(
            get: { databases.pendingDiscard != nil },
            set: { if !$0 { databases.cancelDiscard() } }),
            presenting: databases.pendingDiscard) { destination in
            Button("Cancel", role: .cancel) { databases.cancelDiscard() }
            Button("Discard", role: .destructive) { Task { await databases.discardAndGo(destination) } }
        } message: { _ in
            Text("The row you were editing hasn't been saved yet.")
        }
    }
}

// MARK: - Sidebar

/// The services, then the chosen service's databases, then that database's tables.
private struct DatabaseSidebar: View {
    @EnvironmentObject private var databases: DatabasesModel
    @SwiftUI.State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            if databases.database != nil {
                TextField("Filter tables", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if databases.services.isEmpty {
                        Caption("No database service is added. Add PostgreSQL or MySQL in Settings\u{2026} \u{2192} Services.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        SectionTitle("Services")
                        ForEach(databases.services) { service in
                            Button {
                                Task { await databases.go(to: .service(service.id)) }
                            } label: {
                                ServiceRow(service: service, selected: service.id == databases.selection)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let service = databases.selectedService, service.isRunning {
                        if !databases.databases.isEmpty {
                            SectionTitle("Databases")
                            ForEach(databases.databases, id: \.self) { name in
                                Button {
                                    Task { await databases.go(to: .database(name)) }
                                } label: {
                                    SidebarRow(title: name, symbol: "cylinder", selected: name == databases.database)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if databases.database != nil {
                            SectionTitle("Tables")
                            if databases.tables.isEmpty {
                                if databases.isBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                } else {
                                    Caption(databases.lastError == nil ? "No tables." : "Couldn't read the tables.")
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 4)
                                }
                            } else if filteredTables.isEmpty {
                                Caption("No tables match \u{201C}\(term)\u{201D}.")
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(filteredTables) { table in
                                    Button {
                                        Task { await databases.go(to: .table(table)) }
                                    } label: {
                                        SidebarRow(title: table.displayName,
                                                   symbol: table.isView ? "eye" : "tablecells",
                                                   selected: table.id == databases.table?.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .background(Theme.surface)
        .onChange(of: databases.database) { _ in filter = "" }
    }

    private var term: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredTables: [DatabaseTable] {
        guard !term.isEmpty else { return databases.tables }
        return databases.tables.filter { $0.displayName.localizedCaseInsensitiveContains(term) }
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.inkMuted)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 5)
    }
}

private struct ServiceRow: View {
    let service: DatabaseService
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(state: service.isRunning ? .running : .stopped)
                .frame(width: 14, height: 14)
            Text(service.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(verbatim: service.isRunning ? "\(service.port)" : "Stopped")
                .font(.caption)
                .foregroundStyle(selected ? Theme.onHoney : Theme.inkMuted)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? Theme.onHoney : Theme.ink)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.honey : Color.clear))
        .contentShape(Rectangle())
        .padding(.horizontal, 5)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 14)
                .foregroundStyle(selected ? Theme.onHoney : Theme.inkMuted)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? Theme.onHoney : Theme.ink)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.honey : Color.clear))
        .contentShape(Rectangle())
        .padding(.horizontal, 5)
    }
}

// MARK: - Table

/// The chosen table's name and rows, with its columns' types in the header.
private struct DatabaseTablePane: View {
    @EnvironmentObject private var databases: DatabasesModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(databases.title)
                    .font(Theme.heading(16))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if databases.table != nil {
                    TextField("Search rows", text: Binding(
                        get: { databases.rowSearch },
                        set: { text in databases.setRowSearch(text) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .disabled(databases.draft != nil)
                        .help("Find rows with this text in any column, searched across the whole table")
                }
                if let count = databases.rowCountText, databases.table != nil {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                if let notice = databases.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                if databases.isBusy || databases.isSaving {
                    ProgressView().controlSize(.small)
                }
                if databases.table != nil {
                    if databases.isEditableTable {
                        Button {
                            databases.beginInsert()
                        } label: {
                            Label("New row", systemImage: "plus")
                        }
                        .disabled(databases.draft != nil || databases.isSaving)
                        .help("Add a row at the end of this table")
                    } else if let note = databases.readOnlyNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .help("Only tables with a primary key can be edited here")
                    }
                }
                Button("Reload") { Task { await databases.reload() } }
                    .disabled(!databases.canReload)
                    .help("Read the databases and tables again")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.line).frame(height: 1)
            content
        }
        .background(Theme.surface)
        // The key rides with the dialog: dismissing it clears the pending row before these buttons' tasks
        // could read it.
        .alert("Delete this row?", isPresented: Binding(
            get: { databases.pendingDelete != nil },
            set: { if !$0 { databases.cancelDelete() } }),
            presenting: databases.pendingDelete) { key in
            Button("Cancel", role: .cancel) { databases.cancelDelete() }
            Button("Delete", role: .destructive) { Task { await databases.confirmDelete(key) } }
        } message: { key in
            Text("Delete the row where \(key.description)? This can't be undone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if databases.table != nil, let rows = databases.rows {
            if let text = databases.noRowsText, databases.draft == nil {
                Caption(text)
                    .textSelection(.enabled)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                DatabaseRowsGrid(columns: gridColumns(rows), rows: rows.rows,
                                 modelColumns: databases.columns,
                                 actions: databases.isEditableTable
                                     ? GridActions(
                                         onEdit: { index in await databases.beginEdit(row: index) },
                                         onDelete: { databases.requestDelete(row: $0) })
                                     : nil,
                                 editor: databases.draft.map { draft in
                                     GridEditor(
                                         draft: draft,
                                         row: databases.editingRow,
                                         saving: databases.isSaving,
                                         onText: { databases.setDraftText($0, column: $1) },
                                         onNull: { databases.setDraftNull($0, column: $1) },
                                         onSave: { Task { await databases.saveDraft() } },
                                         onCancel: { databases.cancelDraft() })
                                 })
            }
        } else if let text = databases.detailText {
            Caption(text)
                .textSelection(.enabled)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The table's own columns when they have loaded (names, types, keys), else the result's names alone.
    private func gridColumns(_ rows: DatabaseRows) -> [DatabaseGridColumn] {
        guard databases.columns.isEmpty else {
            return databases.columns.map {
                DatabaseGridColumn(name: $0.name, detail: $0.type, isKey: $0.primary)
            }
        }
        return rows.columns.map { DatabaseGridColumn(name: $0, detail: nil, isKey: false) }
    }
}

private struct DatabaseGridColumn {
    let name: String
    let detail: String?
    let isKey: Bool
}

/// What a row's pencil, trash and cells' clicks do. Passed only where the table can be written. Opening a
/// row answers whether it opened.
private struct GridActions {
    let onEdit: (Int) async -> Bool
    let onDelete: (Int) -> Void
}

/// The one cell clicked open for typing, and the row it belongs to.
private struct InlineCell: Equatable {
    let row: Int
    let column: String
}

/// The open row: its draft, the row it belongs to (nil for a new row), and how to change it.
private struct GridEditor {
    let draft: DatabaseEditDraft
    let row: Int?
    let saving: Bool
    let onText: (String, String) -> Void
    let onNull: (Bool, String) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
}

/// A JSON value being edited: the whole document in a box, checked before it is applied. The read-only
/// twin of the cells' `JSONInspector`.
private struct JSONEditor: View {
    @SwiftUI.State private var text: String
    let onCancel: () -> Void
    let onApply: (String) -> Void

    init(text: String, onCancel: @escaping () -> Void, onApply: @escaping (String) -> Void) {
        _text = SwiftUI.State(initialValue: text)
        self.onCancel = onCancel
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JSON")
                .font(.caption.weight(.semibold))
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(DatabaseJSON.isValid(text) ? Theme.line : Color.red))
                .frame(width: 480, height: 250)
            HStack(spacing: 8) {
                if !DatabaseJSON.isValid(text) {
                    Text("Not valid JSON.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Apply") { onApply(text) }
                    .disabled(!DatabaseJSON.isValid(text))
            }
        }
        .padding(12)
        .frame(width: 504, height: 340)
        .background(Theme.surface)
    }
}

/// A result set as a grid: a row number gutter, then one column per result column, each as wide as its header
/// divider has been dragged, then, where the table can be written, an actions column. A row open for editing
/// replaces its cells with fields; a cell clicked open becomes a field of its own. Scrolls both ways.
private struct DatabaseRowsGrid: View {
    let columns: [DatabaseGridColumn]
    let rows: [[String?]]
    var modelColumns: [DatabaseColumn] = []
    var actions: GridActions?
    var editor: GridEditor?

    @SwiftUI.State private var widths = DatabaseGridWidths(columns: 0)
    /// The column whose edge is being dragged, and the width it had when the drag began.
    @SwiftUI.State private var resizing: Int?
    @SwiftUI.State private var resizeFrom: CGFloat = 0
    @SwiftUI.State private var hovered: Int?
    @SwiftUI.State private var jsonColumn: String?
    /// The cell clicked open, and the row it belongs to; its field replaces that one cell.
    @SwiftUI.State private var inlineCell: InlineCell?
    @FocusState private var focus: String?

    private static let gutter: CGFloat = 42
    /// How wide a column's edge is to the pointer, and how wide the line looks.
    private static let handle: CGFloat = 9
    private static let actionsWidth: CGFloat = 58
    private static let controlsWidth: CGFloat = 176

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        Group {
                            if let editor, editor.row == index, inlineCell?.row == index {
                                inlineRow(index: index, row: row, editor: editor)
                            } else if let editor, editor.row == index {
                                editRow(index: index, editor: editor)
                            } else {
                                plainRow(index: index, row: row)
                            }
                            Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1)
                        }
                    }
                    if let editor, editor.row == nil {
                        editRow(index: nil, editor: editor)
                        Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1)
                    }
                }
                // Small results stay at the top leading corner instead of drifting to the middle.
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
        .background(Theme.surface)
        .onChange(of: columns.count) { _ in
            widths = DatabaseGridWidths(columns: columns.count)
        }
        // The draft is gone: saved, cancelled, or the row closed from elsewhere. The open cell goes with it.
        .onChange(of: editor?.row) { row in
            if let inlineCell, row != inlineCell.row { self.inlineCell = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell(Text(verbatim: "#"), width: Self.gutter, muted: true)
            ForEach(columns.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if columns[index].isKey {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.honeyText)
                        }
                        Text(columns[index].name)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    if let detail = columns[index].detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: widths[index], alignment: .leading)
                .clipped()
                .overlay(alignment: .trailing) { resizeHandle(index) }
            }
            if actions != nil {
                Color.clear.frame(width: Self.actionsWidth)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.ground)
    }

    private func plainRow(index: Int, row: [String?]) -> some View {
        HStack(spacing: 0) {
            cell(Text(verbatim: "\(index + 1)"), width: Self.gutter, muted: true)
            ForEach(columns.indices, id: \.self) { column in
                valueCell(row: index, column: column, row[safe: column] ?? nil)
            }
            if let actions {
                actionButtons(actions, row: index)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if let actions {
                Button("Edit Row\u{2026}") { Task { _ = await actions.onEdit(index) } }
                Button("Delete Row\u{2026}", role: .destructive) { actions.onDelete(index) }
            }
        }
        .onHover { inside in
            if inside {
                hovered = index
            } else if hovered == index {
                hovered = nil
            }
        }
    }

    private func actionButtons(_ actions: GridActions, row: Int) -> some View {
        HStack(spacing: 2) {
            if hovered == row, editor == nil {
                Button { Task { _ = await actions.onEdit(row) } } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit this row")
                Button { actions.onDelete(row) } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this row")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .foregroundStyle(Theme.inkMuted)
        .frame(width: Self.actionsWidth)
    }

    private func editRow(index: Int?, editor: GridEditor) -> some View {
        HStack(spacing: 0) {
            cell(index.map { Text(verbatim: "\($0 + 1)") } ?? Text(verbatim: "new"),
                 width: Self.gutter, muted: true)
            ForEach(columns.indices, id: \.self) { column in
                if let model = modelColumn(at: column) {
                    editCell(model, index: column, editor: editor)
                } else {
                    cell(Text(verbatim: ""), width: widths[column])
                }
            }
            editorControls(editor)
        }
        .padding(.vertical, 3)
        .background(Theme.ground.opacity(0.6))
        .onAppear { focus = firstEditableColumn(editor.draft) }
    }

    private func modelColumn(at index: Int) -> DatabaseColumn? {
        guard columns.indices.contains(index) else { return nil }
        return modelColumns.first { $0.name == columns[index].name }
    }

    @ViewBuilder
    private func editCell(_ column: DatabaseColumn, index: Int, editor: GridEditor) -> some View {
        HStack(spacing: 4) {
            if column.isEditable {
                field(column, editor: editor)
                if column.nullable {
                    Button {
                        editor.onNull(!editor.draft.isNull(column.name), column.name)
                    } label: {
                        Image(systemName: "circle.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(editor.draft.isNull(column.name) ? Theme.honeyText : Theme.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .help(editor.draft.isNull(column.name) ? "Give this field a value" : "Set this field to NULL")
                }
            } else if let shown = editor.draft.shownValue(column.name) {
                Text(verbatim: Self.oneLine(shown))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(nonEditableHelp(column))
            } else {
                Text("NULL")
                    .font(.system(.caption, design: .monospaced))
                    .italic()
                    .foregroundStyle(Theme.inkMuted)
                    .help(nonEditableHelp(column))
            }
        }
        .padding(.horizontal, 8)
        .frame(width: widths[index], alignment: .leading)
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
        }
        .disabled(editor.saving)
    }

    @ViewBuilder
    private func field(_ column: DatabaseColumn, editor: GridEditor) -> some View {
        if editor.draft.isNull(column.name) {
            Text("NULL")
                .font(.system(.caption, design: .monospaced))
                .italic()
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if column.type.lowercased() == "json" || column.type.lowercased() == "jsonb" {
            Button {
                jsonColumn = column.name
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: Self.oneLine(editor.draft.isTouched(column.name)
                        ? editor.draft.text(for: column.name)
                        : editor.draft.placeholder(for: column)))
                        .foregroundStyle(editor.draft.isTouched(column.name) ? Theme.ink : Theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "curlybraces")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.honeyText)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(editor.draft.invalidJSONColumns().contains(column.name) ? Color.red : Theme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit this JSON document")
            .popover(isPresented: Binding(
                get: { jsonColumn == column.name },
                set: { if !$0, jsonColumn == column.name { jsonColumn = nil } })) {
                JSONEditor(text: editor.draft.text(for: column.name),
                           onCancel: { jsonColumn = nil },
                           onApply: { text in
                               editor.onText(text, column.name)
                               jsonColumn = nil
                           })
            }
        } else {
            TextField(editor.draft.placeholder(for: column), text: Binding(
                get: { editor.draft.text(for: column.name) },
                set: { editor.onText($0, column.name) }))
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
                .focused($focus, equals: column.name)
                .onSubmit { focus = nextEditable(after: column.name, in: editor.draft) }
        }
    }

    private func editorControls(_ editor: GridEditor) -> some View {
        HStack(spacing: 6) {
            if editor.saving {
                ProgressView().controlSize(.small)
            }
            Button("Save") { editor.onSave() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editor.saving || !(editor.draft.mode == .insert || editor.draft.hasChanges))
            Button("Cancel") { editor.onCancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .disabled(editor.saving)
        }
        .padding(.horizontal, 8)
        .frame(width: Self.controlsWidth, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
        }
    }

    private func firstEditableColumn(_ draft: DatabaseEditDraft) -> String? {
        draft.columns.first { $0.isEditable }?.name
    }

    private func nextEditable(after name: String, in draft: DatabaseEditDraft) -> String? {
        guard let index = draft.columns.firstIndex(where: { $0.name == name }) else { return nil }
        return draft.columns[(index + 1)...].first { $0.isEditable }?.name
    }

    private func nonEditableHelp(_ column: DatabaseColumn) -> String {
        if column.binary { return "Binary values can't be edited here" }
        if column.generated { return "The database computes this column" }
        if column.identity { return "The database assigns this column" }
        return "Read-only here"
    }

    /// The line between two columns, which the pointer drags to make this column wider or narrower.
    private func resizeHandle(_ index: Int) -> some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: 1)
            .frame(width: Self.handle)
            .contentShape(Rectangle())
            .onHover { inside in
                (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if resizing != index {
                            resizing = index
                            resizeFrom = widths[index]
                        }
                        widths.resize(index, to: resizeFrom + value.translation.width)
                    }
                    .onEnded { _ in resizing = nil }
            )
            .help("Drag to resize this column")
    }

    @ViewBuilder
    private func valueCell(row: Int, column: Int, _ value: String?) -> some View {
        let name = columns[column].name
        if inlineCell == InlineCell(row: row, column: name), editor == nil {
            pendingCell(width: widths[column])
        } else if let value, let document = DatabaseJSON.document(value) {
            JSONCell(preview: document.preview, pretty: document.pretty, width: widths[column])
        } else if let actions, editor == nil, modelColumn(at: column)?.isEditable == true {
            cell(value.map { Text(verbatim: Self.oneLine($0)) } ?? Text("NULL").italic(),
                 width: widths[column], muted: value == nil, selectable: false)
                .help("Click to edit this cell")
                .contentShape(Rectangle())
                .onTapGesture { beginInlineEdit(row: row, column: name, actions: actions) }
        } else {
            cell(value.map { Text(verbatim: Self.oneLine($0)) } ?? Text("NULL").italic(),
                 width: widths[column], muted: value == nil)
                .help(value ?? "NULL")
        }
    }

    /// The cell waiting for its row to be read whole, before its field can hold the full value.
    private func pendingCell(width: CGFloat) -> some View {
        ProgressView()
            .controlSize(.mini)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
            }
    }

    /// Opens one cell for typing. The row is read whole first, so the field holds the full value rather than
    /// the grid's clipped text. Enter saves the one column; Escape puts the cell back.
    private func beginInlineEdit(row: Int, column: String, actions: GridActions) {
        guard editor == nil, inlineCell == nil else { return }
        let cell = InlineCell(row: row, column: column)
        inlineCell = cell
        Task {
            if !(await actions.onEdit(row)), inlineCell == cell {
                inlineCell = nil
            }
        }
    }

    /// A plain row with the clicked cell, and only it, as a field.
    private func inlineRow(index: Int, row: [String?], editor: GridEditor) -> some View {
        HStack(spacing: 0) {
            cell(Text(verbatim: "\(index + 1)"), width: Self.gutter, muted: true)
            ForEach(columns.indices, id: \.self) { column in
                if columns[column].name == inlineCell?.column, let model = modelColumn(at: column) {
                    inlineField(model, index: column, editor: editor)
                } else {
                    valueCell(row: index, column: column, row[safe: column] ?? nil)
                }
            }
            if actions != nil {
                Color.clear.frame(width: Self.actionsWidth)
            }
        }
        .padding(.vertical, 4)
        .onAppear { focus = inlineCell?.column }
    }

    private func inlineField(_ column: DatabaseColumn, index: Int, editor: GridEditor) -> some View {
        TextField("", text: Binding(
            get: { editor.draft.text(for: column.name) },
            set: { editor.onText($0, column.name) }))
            .textFieldStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.honey))
            .focused($focus, equals: column.name)
            .onSubmit { submitInline(editor) }
            .onExitCommand { editor.onCancel() }
            .disabled(editor.saving)
            .padding(.horizontal, 8)
            .frame(width: widths[index], alignment: .leading)
            .clipped()
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
            }
    }

    /// Enter saves the one column and closes; with nothing typed there is nothing to save.
    private func submitInline(_ editor: GridEditor) {
        guard !editor.saving else { return }
        if editor.draft.hasChanges {
            editor.onSave()
        } else {
            editor.onCancel()
        }
    }

    private func cell(_ text: Text, width: CGFloat, muted: Bool = false,
                      selectable: Bool = true) -> some View {
        text
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(muted ? Theme.inkMuted : Theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelectable(selectable)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
            .clipped()
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
            }
    }

    /// Newlines and tabs would make one row taller than the rest; their marks keep it a row.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\u{21B5}")
            .replacingOccurrences(of: "\n", with: "\u{21B5}")
            .replacingOccurrences(of: "\t", with: "\u{2192}")
    }
}

/// A JSON value in the grid: its compact one line, with a mark that it opens. Clicking it shows the whole
/// document, indented, in a panel of its own.
private struct JSONCell: View {
    let preview: String
    let pretty: String
    let width: CGFloat

    @SwiftUI.State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: preview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "curlybraces")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.honeyText)
                    .fixedSize()
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
            .clipped()
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("This is JSON; click to read it whole")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            JSONInspector(text: pretty)
        }
    }
}

/// A JSON document, indented and selectable, in the panel a JSON cell opens.
struct JSONInspector: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 520, height: 320)
        .background(Theme.surface)
    }
}

// MARK: - SQL console

/// One read-only statement, run with ⌘↩, and its last result.
private struct DatabaseConsole: View {
    @EnvironmentObject private var databases: DatabasesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SQL")
                    .font(.caption.weight(.semibold))
                Text("Read-only")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                if databases.isRunningQuery {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await databases.runQuery() }
                } label: {
                    Text("Run")
                        .foregroundStyle(databases.canRunQuery ? Theme.ink : Theme.inkMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!databases.canRunQuery)
                .help("Run this one read-only statement (\u{2318}\u{21A9})")
            }
            editor
            if let result = databases.queryRows {
                resultHeader(result)
                DatabaseRowsGrid(columns: result.columns.map {
                    DatabaseGridColumn(name: $0, detail: nil, isKey: false)
                }, rows: result.rows)
                    .frame(minHeight: 70)
            } else {
                Caption("One read-only statement. \u{2318}\u{21A9} runs it.")
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(get: { databases.query }, set: { databases.setQuery($0) }))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            if databases.query.isEmpty {
                Text("SELECT * FROM users LIMIT 10")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 64)
    }

    private func resultHeader(_ result: DatabaseRows) -> some View {
        HStack(spacing: 8) {
            Text(result.truncated ? "First \(DatabasesModel.rowLimit) rows." : count(result.rows.count))
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
            Spacer()
        }
    }

    private func count(_ rows: Int) -> String {
        rows == 1 ? "1 row" : "\(rows) rows"
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Text selection where a cell is only for reading; a cell that opens for typing keeps its clicks.
private extension View {
    @ViewBuilder func textSelectable(_ enabled: Bool) -> some View {
        if enabled { textSelection(.enabled) } else { self }
    }
}
