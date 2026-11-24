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
                                Task { await databases.select(service: service.id) }
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
                                    Task { await databases.select(database: name) }
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
                                        Task { await databases.select(table: table) }
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
                        .help("Find rows with this text in any column, searched across the whole table")
                }
                if let count = databases.rowCountText, databases.table != nil {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                if databases.isBusy {
                    ProgressView().controlSize(.small)
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
    }

    @ViewBuilder
    private var content: some View {
        if databases.table != nil, let rows = databases.rows {
            if let text = databases.noRowsText {
                Caption(text)
                    .textSelection(.enabled)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                DatabaseRowsGrid(columns: gridColumns(rows), rows: rows.rows)
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

/// A result set as a grid: a row number gutter, then one column per result column, each as wide as its header
/// divider has been dragged. Scrolls both ways; a value is one line, and its whole text is in its tooltip.
/// A JSON object or array shows as its one line and opens, whole and indented, when clicked.
private struct DatabaseRowsGrid: View {
    let columns: [DatabaseGridColumn]
    let rows: [[String?]]

    @SwiftUI.State private var widths = DatabaseGridWidths(columns: 0)
    /// The column whose edge is being dragged, and the width it had when the drag began.
    @SwiftUI.State private var resizing: Int?
    @SwiftUI.State private var resizeFrom: CGFloat = 0

    private static let gutter: CGFloat = 42
    /// How wide a column's edge is to the pointer, and how wide the line looks.
    private static let handle: CGFloat = 9

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            cell(Text(verbatim: "\(index + 1)"), width: Self.gutter, muted: true)
                            ForEach(columns.indices, id: \.self) { column in
                                valueCell(row: index, column: column, row[safe: column] ?? nil)
                            }
                        }
                        .padding(.vertical, 4)
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
        }
        .padding(.vertical, 4)
        .background(Theme.ground)
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
        if let value, let document = DatabaseJSON.document(value) {
            JSONCell(preview: document.preview, pretty: document.pretty, width: widths[column])
        } else {
            cell(value.map { Text(verbatim: Self.oneLine($0)) } ?? Text("NULL").italic(),
                 width: widths[column], muted: value == nil)
                .help(value ?? "NULL")
        }
    }

    private func cell(_ text: Text, width: CGFloat, muted: Bool = false) -> some View {
        text
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(muted ? Theme.inkMuted : Theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
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
