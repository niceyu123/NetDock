import SwiftUI
import NetDockCore

@MainActor @Observable
final class DNSLookupModel {
    var name = "example.com"
    var server = "1.1.1.1"
    var port = "53"
    var type: DNSRecordType = .a
    private(set) var result: DNSLookup?
    private(set) var error: NetDockError?
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private var generation = UUID()

    func lookup() {
        guard !isRunning else { return }
        result = nil; error = nil
        do {
            let query = try DNSQuery(name: name, type: type, server: server, port: EndpointInput.port(port))
            let token = UUID(); generation = token
            result = nil; error = nil; isRunning = true
            task = Task { [weak self] in
                do {
                    let result = try await DNSClient().query(query)
                    guard let self, self.generation == token else { return }
                    self.result = result; self.isRunning = false; self.task = nil
                } catch {
                    guard let self, self.generation == token else { return }
                    self.isRunning = false; self.task = nil
                    if !(error is CancellationError) { self.error = (error as? NetDockError) ?? NetDockError(.dns) }
                }
            }
        } catch { self.error = (error as? NetDockError) ?? NetDockError(.invalidDNSQuery) }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; isRunning = false }
    var copyText: String {
        guard let result else { return "" }
        let response = result.response
        let header = "\(result.query.name) \(result.query.type.title) @\(result.query.resolverEndpoint)\n\(response.status) · \(result.usedTCP ? "TCP" : "UDP") · \(Int(result.elapsed * 1000)) ms"
        return ([header] + response.records.map { "\($0.section.rawValue)\t\($0.name)\t\($0.ttl)\tCLASS\($0.recordClass)\t\($0.typeTitle)\t\($0.value)" }).joined(separator: "\n")
    }
    deinit { task?.cancel() }
}

struct DNSLookupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = DNSLookupModel()
    private enum Field: Hashable { case name, server, port }
    @FocusState private var focused: Field?

    var body: some View {
        @Bindable var model = model
        Form {
            Section(app.t("dnsQuery")) {
                TextField(app.t("dnsName"), text: $model.name)
                    .focused($focused, equals: .name).autocorrectionDisabled()
                    .accessibilityIdentifier("dnsName")
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                Picker(app.t("dnsRecordType"), selection: $model.type) {
                    ForEach(DNSRecordType.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("dnsRecordType")
                TextField(app.t("dnsServer"), text: $model.server)
                    .focused($focused, equals: .server).autocorrectionDisabled()
                    .accessibilityIdentifier("dnsServer")
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                TextField(app.t("dnsPort"), text: $model.port)
                    .focused($focused, equals: .port).accessibilityIdentifier("dnsPort")
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text(app.t("dnsQueryHint")).font(.caption).foregroundStyle(.secondary)
            }.disabled(model.isRunning)
            Section {
                HStack {
                    Button {
                        focused = nil; model.lookup()
                    } label: { Label(app.t("dnsLookup"), systemImage: "magnifyingglass") }
                    .disabled(model.isRunning).keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("dnsLookup")
                    if model.isRunning {
                        ProgressView().controlSize(.small).accessibilityLabel(app.t("dnsLookingUp"))
                        Button(app.t("cancel")) { model.cancel() }.accessibilityIdentifier("dnsCancel")
                    }
                }
            }
            if let error = model.error {
                Section { Label(app.errorText(error), systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                    .accessibilityIdentifier("dnsError")
            }
            if let result = model.result {
                Section(app.t("dnsResult")) {
                    LabeledContent(app.t("dnsStatus"), value: result.response.status).accessibilityIdentifier("dnsStatus")
                    LabeledContent(app.t("dnsServer"), value: result.query.resolverEndpoint)
                    LabeledContent(app.t("dnsTransport"), value: result.usedTCP ? "TCP" : "UDP")
                    LabeledContent(app.t("dnsElapsed"), value: "\(Int(result.elapsed * 1000)) ms")
                    Text("AA: \(result.response.authoritative ? "1" : "0") · RA: \(result.response.recursionAvailable ? "1" : "0")")
                        .font(.caption.monospaced()).accessibilityLabel(app.t("dnsFlagsHint"))
                        .accessibilityValue("AA: \(result.response.authoritative ? "1" : "0"), RA: \(result.response.recursionAvailable ? "1" : "0")")
                    Button(app.t("dnsCopyResult")) { Clipboard.copy(model.copyText) }.accessibilityIdentifier("dnsCopy")
                }
                ForEach(DNSRecord.Section.allCases, id: \.self) { section in
                    let records = result.response.records.filter { $0.section == section }
                    if !records.isEmpty {
                        Section(app.t("dns.section.\(section.rawValue)")) {
                            ForEach(records) { record in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.name).font(.headline)
                                    Text("\(record.typeTitle) · TTL \(record.ttl) · CLASS\(record.recordClass)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(record.value).font(.body.monospaced()).textSelection(.enabled)
                                        .accessibilityIdentifier("dnsRecordValue")
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
                if result.response.records.isEmpty { Section { Text(app.t("dnsNoRecords")) } }
                Section {
                    DisclosureGroup(app.t("dnsRawResponse")) {
                        Text(PayloadCodec.hex(result.response.rawData)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text(app.t("dnsResultHint")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(app.t("dnsQuery"))
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.cancel() } }
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(app.t("done")) { focused = nil }.accessibilityIdentifier("dnsDismissKeyboard")
            }
            #endif
        }
    }
}
