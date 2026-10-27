import SwiftUI
import NetDockCore

struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var runtime: SessionRuntime
    var onEdit: () -> Void
    @State private var inspectorVisible = true
    @State private var showClients = false
    @State private var showConnection = false
    private enum EndpointField: Hashable { case host, port }
    @FocusState private var endpointField: EndpointField?

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 780
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    statusBar
                    if let error = runtime.inputError ?? runtime.periodic.lastError ?? runtime.lastError {
                        Label(app.errorText(error), systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(.red.opacity(0.06)).textSelection(.enabled)
                    }
                    LogView(runtime: runtime)
                    if !wide || !inspectorVisible {
                        Divider()
                        SendPanel(runtime: runtime, showClients: { showClients = true })
                            .padding(12).background(.background)
                    }
                }
                if wide && inspectorVisible {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            connectionDetails
                            if runtime.config.mode.isServer { PeerListView(runtime: runtime) }
                            Divider()
                            SendPanel(runtime: runtime, showClients: { showClients = true })
                        }.padding(16)
                    }.frame(width: 310)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        if wide { inspectorVisible.toggle() } else { showConnection = true }
                    } label: { Label(app.t("showInspector"), systemImage: "sidebar.right") }
                    .accessibilityIdentifier("showInspector")
                }
            }
        }
        .navigationTitle(runtime.config.name)
        .onChange(of: runtime.isConfigurationLocked) { _, locked in
            if locked { endpointField = nil }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if endpointField != nil {
                    Spacer()
                    Button(app.t("done")) { endpointField = nil }
                        .accessibilityIdentifier("dismissEndpointKeyboard")
                }
            }
        }
        #endif
        .sheet(isPresented: $showClients) {
            NavigationStack {
                PeerListView(runtime: runtime).padding()
                    .navigationTitle(app.t(runtime.config.mode.isUDP ? "sources" : "clients"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(app.t("done")) { showClients = false } } }
            }
            .presentationDetents([.medium, .large])
            #if os(macOS)
            .frame(width: 460, height: 440)
            #endif
        }
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                ScrollView { connectionDetails.padding() }
                    .navigationTitle(app.t("configuration"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(app.t("done")) { showConnection = false } } }
            }.presentationDetents([.medium, .large])
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { sessionStatus; Spacer(minLength: 12); connectionButton }
                VStack(alignment: .leading, spacing: 10) { sessionStatus; connectionButton }
            }
            endpointFields
            if let endpointError = runtime.endpointError {
                Label(app.errorText(endpointError), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("endpointError")
            }
            HStack {
                if runtime.isEndpointDirty {
                    Button(app.t("save")) {
                        if app.saveEndpoint(runtime) { endpointField = nil }
                    }
                    .disabled(runtime.isConfigurationLocked)
                    .accessibilityIdentifier("saveEndpoint")
                }
                Spacer()
                Text("TX \(runtime.sentBytes) · RX \(runtime.receivedBytes) B").lineLimit(1)
                    .accessibilityIdentifier("trafficCounters")
            }.font(.caption.monospaced()).foregroundStyle(.secondary)
            if let endpoint = runtime.localEndpoint {
                Text("\(app.t("local")): \(endpoint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).accessibilityIdentifier("actualLocalEndpoint")
            }
        }.padding(12).background(.bar)
    }

    private var sessionStatus: some View {
        HStack(spacing: 12) {
            Text(runtime.config.mode.title).font(.subheadline).foregroundStyle(.secondary)
            status
            if runtime.isConfigurationLocked {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    .help(app.t("error.activeSession"))
                    .accessibilityLabel(app.t("error.activeSession"))
            }
        }
    }

    private var endpointFields: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if !runtime.config.mode.isServer {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.t("host")).font(.caption).foregroundStyle(.secondary)
                    TextField(app.t("host"), text: $runtime.endpointHost)
                        .focused($endpointField, equals: .host)
                        .accessibilityLabel(app.t("host"))
                        .accessibilityIdentifier("endpointHost")
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }
                .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(app.t(runtime.config.mode.isServer ? "localPort" : "remotePort"))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(app.t(runtime.config.mode.isServer ? "localPort" : "remotePort"), text: $runtime.endpointPort)
                    .focused($endpointField, equals: .port)
                    .accessibilityLabel(app.t(runtime.config.mode.isServer ? "localPort" : "remotePort"))
                    .accessibilityIdentifier("endpointPort")
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            .frame(maxWidth: runtime.config.mode.isServer ? .infinity : 110)
        }
        .font(.body.monospaced())
        .textFieldStyle(.roundedBorder)
        .disabled(runtime.isConfigurationLocked)
        .onSubmit { if app.saveEndpoint(runtime) { endpointField = nil } }
    }
    private var status: some View {
        HStack(spacing: 8) {
            Image(systemName: runtime.state == .ready || runtime.state == .listening ? "checkmark.circle.fill" :
                    runtime.state == .failed ? "exclamationmark.circle.fill" : "circle")
                .foregroundStyle(runtime.state == .failed ? Color.red : runtime.state.isActive ? .green : .secondary)
            Text(app.t(runtime.config.mode.isServer && runtime.state == .connecting ? "startingListening" : runtime.config.mode.stateKey(runtime.state)))
                .font(.headline)
            if runtime.state == .connecting || runtime.state == .starting || runtime.state == .stopping { ProgressView().controlSize(.small) }
        }.accessibilityElement(children: .combine).accessibilityIdentifier("connectionState")
    }
    private var connectionButton: some View {
        Button {
            Task {
                if runtime.state.isActive { await runtime.stop() }
                else { endpointField = nil; await app.startSession(runtime) }
            }
        } label: {
            Label(app.t(runtime.state.isActive ? (runtime.config.mode.isUDP ? "stopSession" : runtime.config.mode.isServer ? "stopListening" : "disconnect") :
                        (runtime.config.mode.isUDP ? "startSession" : runtime.config.mode.isServer ? "startListening" : "connect")),
                  systemImage: runtime.state.isActive ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(runtime.state == .stopping || (runtime.isConfigurationLocked && !runtime.state.isActive))
        .keyboardShortcut("k", modifiers: .command).accessibilityIdentifier("toggleConnection")
    }
    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(app.t("configuration"), systemImage: "slider.horizontal.3").font(.headline)
            LabeledContent(app.t("mode"), value: runtime.config.mode.title)
            Text(runtime.config.endpointDescription).font(.body.monospaced()).textSelection(.enabled)
            if let endpoint = runtime.localEndpoint {
                LabeledContent(app.t("local"), value: endpoint).font(.body.monospaced()).textSelection(.enabled)
            }
            Text(app.t(runtime.config.mode.isUDP ? "udpHint" : runtime.config.mode.isServer ? "listenHint" : "hostHint"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(app.t("statistics")).font(.headline)
            LabeledContent(app.t("packetCounts"), value: "TX \(runtime.sentPackets) · RX \(runtime.receivedPackets)")
                .font(.caption.monospaced())
            if !runtime.config.mode.isUDP {
                LabeledContent(app.t("connectedDuration"), value: "\(Int(runtime.connectedDuration)) \(app.t("seconds"))")
            }
            Button(app.t("edit"), action: onEdit).disabled(runtime.isConfigurationLocked).accessibilityIdentifier("editSession")
        }
    }
}
