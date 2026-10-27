import SwiftUI
import NetDockCore

struct SessionEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var config: SessionConfig
    @State private var port = ""
    @State private var clientLocalPort = ""
    @State private var error: NetDockError?
    private enum Field: Hashable { case name, host, port, localHost, localPort }
    @FocusState private var focusedField: Field?
    var onSave: (SessionConfig) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(app.t("name"), text: $config.name)
                        .focused($focusedField, equals: .name).accessibilityIdentifier("sessionName")
                    Picker(app.t("mode"), selection: $config.mode) {
                        ForEach(SessionMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.accessibilityIdentifier("sessionMode")
                }
                Section(app.t("endpoint")) {
                    if !config.mode.isServer {
                        TextField(app.t("host"), text: $config.host)
                            .focused($focusedField, equals: .host)
                            .autocorrectionDisabled().accessibilityIdentifier("host")
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    }
                    TextField(app.t(config.mode.isServer ? "localPort" : "remotePort"), text: $port)
                        .focused($focusedField, equals: .port).monospaced().accessibilityIdentifier("port")
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                    if config.mode.isUDP {
                        TextField(app.t("localAddress"), text: $config.localHost)
                            .focused($focusedField, equals: .localHost).autocorrectionDisabled()
                            .accessibilityIdentifier("localAddress")
                        if config.mode == .udpClient {
                            TextField(app.t("optionalLocalPort"), text: $clientLocalPort)
                                .focused($focusedField, equals: .localPort).monospaced()
                                .accessibilityIdentifier("clientLocalPort")
                            #if os(iOS)
                                .keyboardType(.numberPad)
                            #endif
                        }
                    }
                    Text(app.t(config.mode.isUDP ? "udpConfigurationHint" : config.mode.isServer ? "listenHint" : "hostHint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(app.errorText(error)).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .onSubmit { focusedField = nil }
            .navigationTitle(app.t("sessionConfiguration"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(app.t("cancel")) { dismiss() }.accessibilityIdentifier("cancelSession")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(app.t("save")) {
                        do {
                            let number = try EndpointInput.port(port)
                            if config.mode.isServer { config.localPort = number } else { config.remotePort = number }
                            if config.mode == .udpClient {
                                config.localPort = clientLocalPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : try EndpointInput.port(clientLocalPort)
                            }
                            let valid = try config.validated()
                            if onSave(valid) { dismiss() }
                            else {
                                self.error = app.storageError ?? NetDockError(.storage)
                                app.storageError = nil
                            }
                        } catch { self.error = (error as? NetDockError) ?? NetDockError(.invalidPort) }
                    }.accessibilityIdentifier("saveSession")
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(app.t("done")) { focusedField = nil }
                        .accessibilityIdentifier("dismissEditorKeyboard")
                }
                #endif
            }
        }
        .onAppear {
            port = String(config.mode.isServer ? config.localPort : config.remotePort)
            clientLocalPort = config.localPort == 0 ? "" : String(config.localPort)
        }
        .onChange(of: config.mode) { _, mode in
            if mode == .udpClient { config.localPort = 0; clientLocalPort = "" }
            port = String(mode.isServer ? (config.localPort == 0 ? 9000 : config.localPort) : config.remotePort)
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
    }
}
