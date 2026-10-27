import SwiftUI
import NetDockCore
import UniformTypeIdentifiers

struct LogView: View {
    @Environment(AppModel.self) private var app
    @Bindable var runtime: SessionRuntime
    @State private var search = ""
    @State private var direction: TrafficRecord.Direction?
    @State private var exportDocument = DataFileDocument()
    @State private var exportType = UTType.json
    @State private var showExport = false
    @State private var preparingExport = false
    private var visibleRecords: [TrafficRecord] {
        let query = TrafficQuery(search: search, direction: direction)
        return runtime.records.filter(query.matches)
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack { logTitle; Spacer(); encodingPicker; logActions }
                HStack { encodingPicker; Spacer(); logActions }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            HStack {
                TextField(app.t("searchLogs"), text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("logSearch")
                Menu {
                    Button(app.t("allDirections")) { direction = nil }
                    Button("TX") { direction = .tx }; Button("RX") { direction = .rx }; Button("SYS") { direction = .system }
                } label: { Label(direction?.rawValue ?? app.t("allDirections"), systemImage: "line.3.horizontal.decrease") }
                    .accessibilityIdentifier("logDirection")
            }.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                List(visibleRecords) { record in
                    LogRow(record: record, encoding: runtime.config.displayEncoding, onReply: runtime.config.mode == .udpServer && record.direction == .rx ? {
                        if let source = runtime.peers.first(where: { $0.endpoint == record.remoteEndpoint }) {
                            runtime.target = source.id; runtime.explicitUDPTarget = false
                        } else { runtime.inputError = NetDockError(.peerMissing) }
                    } : nil).id(record.id)
                }
                .listStyle(.plain).accessibilityIdentifier("trafficLog")
                .overlay {
                    if visibleRecords.isEmpty {
                        ContentUnavailableView(app.t(runtime.records.isEmpty ? "noTraffic" : "noMatchingLogs"), systemImage: "text.alignleft",
                                               description: Text(app.t(runtime.config.mode.isUDP ? "udpHint" : "tcpStreamHint")))
                    }
                }
                .onChange(of: runtime.records.last?.id) { _, id in
                    if runtime.config.autoScroll, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: exportType, defaultFilename: "NetDock-Logs") { result in
            if case .failure(let error) = result { runtime.inputError = NetDockError(.storage, detail: error.localizedDescription) }
        }
    }
    private func prepareExport(json: Bool) {
        let records = visibleRecords
        preparingExport = true
        Task {
            defer { preparingExport = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    json ? try TrafficExport.json(records) : Data(TrafficExport.text(records).utf8)
                }.value
                exportDocument = DataFileDocument(data: data); exportType = json ? .json : .plainText; showExport = true
            } catch { runtime.inputError = (error as? NetDockError) ?? NetDockError(.storage) }
        }
    }
    private var logTitle: some View { Text(app.t("logs")).font(.headline) }
    private var encodingPicker: some View {
        Picker(app.t("displayEncoding"), selection: Binding(get: { runtime.config.displayEncoding }, set: {
            var config = runtime.config; config.displayEncoding = $0; app.save(config)
        })) {
            Text("UTF-8").tag(DataEncoding.utf8)
            Text("HEX").tag(DataEncoding.hex)
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 170)
            .accessibilityLabel(app.t("displayEncoding")).accessibilityIdentifier("displayEncoding")
    }
    private var logActions: some View {
        HStack {
            Menu {
                Text(app.t("exportPrivacyHint"))
                Button(app.t("exportText")) { prepareExport(json: false) }
                Button(app.t("exportJSON")) { prepareExport(json: true) }
            } label: { Label(app.t("exportLogs"), systemImage: "square.and.arrow.up") }
                .labelStyle(.iconOnly).disabled(preparingExport || visibleRecords.isEmpty).accessibilityIdentifier("exportLogs")
            Toggle(isOn: Binding(get: { runtime.config.autoScroll }, set: {
                var config = runtime.config; config.autoScroll = $0; app.save(config)
            })) { Label(app.t("autoScroll"), systemImage: "arrow.down.to.line") }
                .toggleStyle(.button).labelStyle(.iconOnly).help(app.t("autoScroll"))
            Button { runtime.clearLogs() } label: { Label(app.t("clearLogs"), systemImage: "trash") }
                .labelStyle(.iconOnly).help(app.t("clearLogs"))
                .keyboardShortcut("l", modifiers: .command).accessibilityIdentifier("clearLogs")
        }
    }
}

private struct LogRow: View {
    @Environment(AppModel.self) private var app
    let record: TrafficRecord
    let encoding: DataEncoding
    var onReply: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(6)))
                    .foregroundStyle(.secondary)
                Text(record.direction.rawValue).fontWeight(.semibold)
                    .foregroundStyle(record.direction == .rx ? Color.green : record.direction == .tx ? .blue : .secondary)
                Text(record.protocolKind.rawValue).foregroundStyle(.secondary)
                if record.direction != .system { Text("\(record.size) B").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }.font(.caption.monospaced())
            if let endpoint = record.remoteEndpoint {
                Text("\(app.t("remote")): \(endpoint)" + (record.localEndpoint.map { " · \(app.t("local")): \($0)" } ?? ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = record.error {
                Text(app.errorText(error)).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let key = record.messageKey {
                Text(app.t(key)).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(payloadText).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if record.size > 512 {
                    Button(app.t(expanded ? "collapse" : "showAllBytes")) { expanded.toggle() }.font(.caption)
                }
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            if let onReply { Button(app.t("replySource"), action: onReply) }
            if let remote = record.remoteEndpoint { Button(app.t("copyEndpoint")) { Clipboard.copy(remote) } }
            if !record.payload.isEmpty {
                Button(app.t("copyHex")) { Clipboard.copy(PayloadCodec.hex(record.payload)) }
                if let text = PayloadCodec.text(record.payload) {
                    Button(app.t("copyText")) { Clipboard.copy(text) }
                }
            }
        }
    }
    private var payloadText: String {
        if encoding == .utf8 {
            // Validate the whole chunk first; UTF-8 code points can span TCP reads.
            guard let text = PayloadCodec.text(record.payload) else { return app.t("invalidUTF8") + "\n" + PayloadCodec.hex(Data(record.payload.prefix(expanded ? record.size : 512))) }
            return expanded ? text : String(text.prefix(512))
        }
        let bytes = expanded ? record.payload : Data(record.payload.prefix(512))
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            String(format: "%08X  ", offset) + PayloadCodec.hex(bytes.subdata(in: offset..<min(offset + 16, bytes.count)))
        }.joined(separator: "\n")
    }
}
