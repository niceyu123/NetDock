#if os(macOS)
import SwiftUI
import AppKit
import NetDockCore
import UniformTypeIdentifiers

@MainActor @Observable
private final class ConnectionMonitorModel {
    private let collector = ConnectionMonitorCollector()
    private var diff = ConnectionMonitorDiff()
    private(set) var snapshot: MonitorSnapshot?
    private(set) var isRefreshing = false
    private(set) var latestCoverage: MonitorCoverage?
    private(set) var isStale = false

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let next = await collector.collect()
        guard !Task.isCancelled else { return }
        latestCoverage = next.coverage
        let applied = diff.apply(next)
        isStale = !applied || (next.coverage.systemSnapshotReadable && !next.coverage.systemSnapshotComplete)
        if applied { snapshot = next }
    }
    func monitor(every seconds: Int) async {
        if snapshot == nil { await refresh() }
        guard seconds > 0 else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
    func rows(at date: Date, filter: MonitorFilter, sort: [MonitorRowComparator]) -> [MonitorRow] {
        MonitorQuery.rows(diff.rows(at: date), filter: filter, sort: sort)
    }
}

struct ConnectionMonitorView: View {
    @Environment(AppModel.self) private var app
    @State private var model = ConnectionMonitorModel()
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var localPort = ""
    @State private var transport: MonitorTransport?
    @State private var interval = 2
    @State private var isPaused = false
    @State private var selection: MonitorConnectionIdentity?
    @State private var sortOrder = [MonitorRowComparator(.processName), MonitorRowComparator(.pid), MonitorRowComparator(.localPort)]
    @State private var showExport = false
    @State private var exportDocument = MonitorExportDocument(data: Data())
    @State private var exportType = UTType.json
    @State private var preparingExport = false
    @State private var exportFailed = false
    @State private var showFieldHelp = false

    private var columnHelp: [(title: String, explanation: String)] {
        ["process", "pid", "protocol", "localAddress", "localPort", "remoteAddress", "remotePort", "tcpState", "change"].map {
            (title: $0 == "pid" ? "PID" : app.t("monitor.\($0)"), explanation: app.t("monitor.columnHelp.\($0)"))
        }
    }

    private var parsedPort: UInt16? { UInt16(localPort.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var invalidPort: Bool { !localPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedPort == nil }
    private var schedule: Int { isPaused ? 0 : interval }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                heading
                scopeNotice.padding(.horizontal).padding(.bottom, 10)
                filters.padding(.horizontal).padding(.bottom, 10)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let rows = invalidPort ? [] : model.rows(at: context.date,
                        filter: MonitorFilter(search: search, transport: transport, localPort: parsedPort), sort: sortOrder)
                    VStack(spacing: 0) {
                        connectionTable(rows)
                            .frame(minHeight: 0, maxHeight: .infinity)
                            .overlay {
                                if rows.isEmpty {
                                    ContentUnavailableView(app.t(invalidPort ? "monitor.invalidPort" : "monitor.empty"), systemImage: "network",
                                        description: Text(app.t(invalidPort ? "monitor.portHint" : "monitor.emptyHint")))
                                }
                            }
                        if let row = rows.first(where: { $0.id == selection }) { details(row) }
                        footer(rows: rows)
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .navigationTitle(app.t("monitor.title"))
        .task(id: schedule) { await model.monitor(every: schedule) }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: exportType,
                      defaultFilename: "NetDock-connections") { result in
            if case .failure = result { exportFailed = true }
        }
        .alert(app.t("monitor.exportFailed"), isPresented: $exportFailed) {
            Button(app.t("done"), role: .cancel) { }
        } message: { Text(app.t("monitor.exportFailedHint")) }
    }

    private var heading: some View {
        HStack(alignment: .center) {
            Text(app.t("monitor.title")).font(.title2.bold())
            Button { showFieldHelp = true } label: {
                Label(app.t("monitor.fieldHelp"), systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("monitorFieldHelp")
            .popover(isPresented: $showFieldHelp, arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(app.t("monitor.fieldHelp")).font(.headline)
                            Spacer()
                            Button(app.t("done")) { showFieldHelp = false }
                                .keyboardShortcut(.cancelAction)
                        }
                        ForEach(columnHelp, id: \.title) { column in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(column.title).font(.subheadline.bold())
                                Text(column.explanation).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }.padding()
                }.frame(width: 380, height: 460)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel(app.t("monitor.refreshing")) }
            Button { Task { await model.refresh() } } label: {
                Label(app.t("monitor.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing).keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("monitorRefresh")
        }.padding()
    }

    private var scopeNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(app.t("monitor.scope.\((model.snapshot?.coverage.scope ?? model.latestCoverage?.scope)?.rawValue ?? "pending")"), systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
            Text(app.t("monitor.scopeLimit"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let coverage = model.latestCoverage {
                Text("\(app.t("monitor.readableProcesses")): \(coverage.readableProcessCount) / \(coverage.enumeratedProcessCount)")
                    .font(.caption).foregroundStyle(.secondary)
                if coverage.systemSnapshotReadable {
                    Text("\(app.t("monitor.systemSockets")): \(coverage.systemSocketCount) · \(app.t("monitor.unattributed")): \(coverage.unattributedConnectionCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !coverage.issues.isEmpty {
                    Text(MonitorIssue.allCases.compactMap { issue in
                        coverage.issues[issue].map { "\(app.t("monitor.issue.\(issue.rawValue)")): \($0)" }
                    }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.isStale {
                    Text(app.t("monitor.stale")).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine).accessibilityIdentifier("monitorScope")
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { searchField; protocolPicker; portField }
                VStack(alignment: .leading) { searchField; HStack { protocolPicker; portField; Spacer() } }
            }
            HStack {
                Picker(app.t("monitor.interval"), selection: $interval) {
                    Text(app.t("monitor.interval.1")).tag(1)
                    Text(app.t("monitor.interval.2")).tag(2)
                    Text(app.t("monitor.interval.5")).tag(5)
                }
                .fixedSize().accessibilityIdentifier("monitorInterval")
                Button {
                    isPaused.toggle()
                } label: {
                    Label(app.t(isPaused ? "monitor.resume" : "monitor.pause"), systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .accessibilityIdentifier("monitorPause")
                Spacer()
                Text(app.t(isPaused ? "monitor.paused" : "monitor.live")).font(.caption).foregroundStyle(.secondary)
            }
            if invalidPort { Text(app.t("monitor.portHint")).font(.caption).foregroundStyle(.red) }
        }
    }
    private var searchField: some View {
        HStack(spacing: 6) {
            Button { searchFocused = true } label: {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel(app.t("monitor.focusSearch"))
            .help(app.t("monitor.focusSearch"))
            TextField(app.t("monitor.search"), text: $search)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityIdentifier("monitorSearch")
                .accessibilityLabel(app.t("monitor.search"))
                .onExitCommand { search = "" }
            if !search.isEmpty {
                Button { search = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).accessibilityIdentifier("monitorClearSearch")
                .accessibilityLabel(app.t("monitor.clearSearch"))
                .help(app.t("monitor.clearSearch"))
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(minWidth: 200)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(searchFocused ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: searchFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
        .help(app.t("monitor.searchHint"))
    }
    private var protocolPicker: some View {
        Picker(app.t("monitor.protocol"), selection: $transport) {
            Text(app.t("monitor.allProtocols")).tag(Optional<MonitorTransport>.none)
            ForEach(MonitorTransport.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }.labelsHidden().frame(minWidth: 90, idealWidth: 110, maxWidth: 130)
            .accessibilityLabel(app.t("monitor.protocol")).accessibilityIdentifier("monitorProtocol")
    }
    private var portField: some View {
        TextField(app.t("monitor.localPortQuery"), text: $localPort)
            .textFieldStyle(.roundedBorder).frame(width: 135)
            .accessibilityLabel(app.t("monitor.localPortQuery")).accessibilityIdentifier("monitorPortQuery")
            .help(app.t("monitor.portQueryHint"))
    }

    private func connectionTable(_ rows: [MonitorRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(app.t("monitor.process"), sortUsing: MonitorRowComparator(.processName)) { row in
                cell(row.connection.processName ?? app.t("monitor.unknownProcess"), row: row)
            }.width(min: 110, ideal: 145)
            TableColumn("PID", sortUsing: MonitorRowComparator(.pid)) { row in
                cell(row.id.process.map { String($0.pid) } ?? "—", row: row)
            }.width(min: 55, ideal: 65, max: 90)
            TableColumn(app.t("monitor.protocol"), sortUsing: MonitorRowComparator(.transport)) { row in
                cell("\(row.connection.transport.rawValue) · \(row.connection.family.rawValue)", row: row)
            }.width(min: 100, ideal: 120, max: 160)
            TableColumn(app.t("monitor.localAddress"), sortUsing: MonitorRowComparator(.localAddress)) { row in
                cell(row.connection.local.address, row: row, monospaced: true)
            }.width(min: 110, ideal: 150)
            TableColumn(app.t("monitor.localPort"), sortUsing: MonitorRowComparator(.localPort)) { row in
                cell(String(row.connection.local.port), row: row)
            }.width(min: 65, ideal: 80, max: 110)
            TableColumn(app.t("monitor.remoteAddress"), sortUsing: MonitorRowComparator(.remoteAddress)) { row in
                cell(row.connection.remote.address, row: row, monospaced: true)
            }.width(min: 110, ideal: 150)
            TableColumn(app.t("monitor.remotePort"), sortUsing: MonitorRowComparator(.remotePort)) { row in
                cell(String(row.connection.remote.port), row: row)
            }.width(min: 65, ideal: 80, max: 110)
            TableColumn(app.t("monitor.tcpState"), sortUsing: MonitorRowComparator(.tcpState)) { row in
                cell(row.connection.stateName, row: row, monospaced: true)
            }.width(min: 90, ideal: 115)
            TableColumn(app.t("monitor.change"), sortUsing: MonitorRowComparator(.change)) { row in
                Label(app.t("monitor.change.\(row.change.rawValue)"), systemImage: changeSymbol(row.change))
                    .foregroundStyle(changeColor(row.change)).font(.callout)
            }.width(min: 80, ideal: 105)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .background(MonitorTableHeaderHelp(explanations: columnHelp.map(\.explanation)))
        .accessibilityIdentifier("monitorTable")
        .contextMenu(forSelectionType: MonitorConnectionIdentity.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button(app.t("monitor.copyLocal")) { Clipboard.copy(row.connection.local.formatted) }
                Button(app.t("monitor.copyRemote")) { Clipboard.copy(row.connection.remote.formatted) }
            }
        }
    }

    private func cell(_ text: String, row: MonitorRow, monospaced: Bool = false) -> some View {
        Text(text)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .lineLimit(1).truncationMode(.middle)
            .foregroundStyle(row.change == .disappeared ? .secondary : .primary)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(row.change == .unchanged ? .clear : changeColor(row.change).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .help(text)
    }
    private func details(_ row: MonitorRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Label(app.t("monitor.details"), systemImage: "info.circle").font(.headline)
                Spacer()
                Button { selection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(app.t("monitor.closeDetails"))
                    .accessibilityLabel(app.t("monitor.closeDetails"))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text(app.t("monitor.process")).foregroundStyle(.secondary)
                    Text("\(row.connection.processName ?? app.t("monitor.unknownProcess")) · PID \(row.id.process.map { String($0.pid) } ?? "—") · FD \(row.id.fileDescriptor.map(String.init) ?? "—")")
                }
                GridRow {
                    Text(app.t("monitor.processStarted")).foregroundStyle(.secondary)
                    if let process = row.id.process {
                        Text(process.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                    } else { Text(app.t("monitor.unknownProcess")) }
                }
                GridRow {
                    Text(app.t("monitor.localEndpoint")).foregroundStyle(.secondary)
                    HStack {
                        Text(row.connection.local.formatted).font(.system(.body, design: .monospaced))
                        Button { Clipboard.copy(row.connection.local.formatted) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help(app.t("monitor.copyLocal")).accessibilityLabel(app.t("monitor.copyLocal"))
                    }
                }
                GridRow {
                    Text(app.t("monitor.remoteEndpoint")).foregroundStyle(.secondary)
                    HStack {
                        Text(row.connection.remote.formatted).font(.system(.body, design: .monospaced))
                        Button { Clipboard.copy(row.connection.remote.formatted) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help(app.t("monitor.copyRemote")).accessibilityLabel(app.t("monitor.copyRemote"))
                    }
                }
                GridRow {
                    Text(app.t("monitor.lastSeen")).foregroundStyle(.secondary)
                    Text(row.lastSeenAt, format: .dateTime.hour().minute().second())
                }
            }.textSelection(.enabled)
            if row.change == .disappeared { Text(app.t("monitor.disappearanceHint")).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(rows: [MonitorRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack {
                Text("\(app.t("monitor.visibleRows")): \(rows.count)").font(.caption)
                if let snapshot = model.snapshot {
                    Text(snapshot.collectedAt, format: .dateTime.hour().minute().second())
                        .font(.caption).foregroundStyle(.secondary).help(app.t("monitor.sampledAt"))
                }
                Spacer()
                Menu {
                    Button("CSV") { prepareExport(.csv, rows: rows) }
                    Button("JSON") { prepareExport(.json, rows: rows) }
                } label: { Label(app.t("monitor.export"), systemImage: "square.and.arrow.up") }
                .disabled(rows.isEmpty || preparingExport || model.snapshot == nil)
                .accessibilityIdentifier("monitorExport")
            }
            Text(app.t("monitor.sortHint")).font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal).padding(.bottom, 8)
    }
    @MainActor private func prepareExport(_ format: MonitorExportFormat, rows: [MonitorRow]) {
        guard let snapshot = model.snapshot, !preparingExport else { return }
        preparingExport = true
        Task {
            defer { preparingExport = false }
            do {
                let data = try await Task.detached(priority: .utility) {
                    try ConnectionMonitorExport.data(snapshot: snapshot, rows: rows, format: format)
                }.value
                exportDocument = MonitorExportDocument(data: data)
                exportType = format == .csv ? .commaSeparatedText : .json
                showExport = true
            } catch { exportFailed = true }
        }
    }
    private func changeColor(_ change: MonitorChange) -> Color {
        switch change { case .added: .green; case .changed: .orange; case .disappeared: .secondary; case .unchanged: .primary }
    }
    private func changeSymbol(_ change: MonitorChange) -> String {
        switch change { case .added: "plus.circle"; case .changed: "arrow.triangle.2.circlepath"; case .disappeared: "minus.circle"; case .unchanged: "circle" }
    }
}

/// SwiftUI's macOS 14 TableColumn only accepts Text labels. Use the public AppKit
/// header tooltip API without replacing the native table or its sorting behavior.
private struct MonitorTableHeaderHelp: NSViewRepresentable {
    let explanations: [String]

    func makeNSView(context: Context) -> HeaderHelpView { HeaderHelpView() }
    func updateNSView(_ view: HeaderHelpView, context: Context) {
        view.explanations = explanations
        // Table columns may be installed later in the same SwiftUI update.
        DispatchQueue.main.async { [weak view] in view?.applyHelp() }
    }

    final class HeaderHelpView: NSView {
        var explanations: [String] = []
        private weak var configuredTable: NSTableView?
        private var columnIdentifiers: [NSUserInterfaceItemIdentifier] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyHelp()
        }

        override func layout() {
            super.layout()
            applyHelp()
        }

        func applyHelp() {
            guard window != nil, !explanations.isEmpty else { return }
            var ancestor = superview
            while let container = ancestor {
                if let table = matchingTable(in: container) {
                    if configuredTable !== table {
                        configuredTable = table
                        columnIdentifiers = table.tableColumns.map(\.identifier)
                    }
                    // Keep each description attached to its column after user reordering.
                    let helpByID = Dictionary(uniqueKeysWithValues: zip(columnIdentifiers, explanations))
                    for column in table.tableColumns {
                        guard let help = helpByID[column.identifier], column.headerToolTip != help else { continue }
                        column.headerToolTip = help
                        column.headerCell.setAccessibilityHelp(help)
                    }
                    return
                }
                ancestor = container.superview
            }
        }

        private func matchingTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView,
               table.tableColumns.count == explanations.count { return table }
            for child in view.subviews {
                if let table = matchingTable(in: child) { return table }
            }
            return nil
        }
    }
}

private struct MonitorExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
