import SwiftUI
import NetDockCore

struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var runtime: SessionRuntime
    var onEdit: () -> Void
    @State private var showClients = false
    private enum EndpointField: Hashable { case host, port }
    @FocusState private var endpointField: EndpointField?

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            ScrollView {
                workspace(spacious: geometry.size.width >= 700, scrolling: true,
                          logHeight: max(240, geometry.size.height * 0.4))
            }
            #else
            let spacious = geometry.size.width >= 700 && geometry.size.height >= 620
            if geometry.size.height < 600 || geometry.size.width < 500 {
                ScrollView { workspace(spacious: false, scrolling: true) }
            } else {
                workspace(spacious: spacious, scrolling: false)
            }
            #endif
        }
        #if os(macOS)
        .navigationTitle("")
        #else
        .navigationTitle(runtime.config.name)
        #endif
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
    }

    private func workspace(spacious: Bool, scrolling: Bool, logHeight: CGFloat = 240) -> some View {
        VStack(spacing: 12) {
            statusBar
                .workspaceCard()
            if let error = runtime.inputError ?? runtime.periodic.lastError ?? runtime.lastError {
                Label(app.errorText(error), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }
            LogView(runtime: runtime)
                .frame(minHeight: scrolling ? logHeight : 140, maxHeight: scrolling ? logHeight : .infinity)
                .workspaceCard()
                .layoutPriority(1)
            Group {
                if scrolling {
                    SendPanel(runtime: runtime, showClients: { showClients = true }).padding(12)
                } else {
                    ScrollView {
                        SendPanel(runtime: runtime, showClients: { showClients = true })
                            .padding(spacious ? 16 : 12)
                    }
                    .frame(height: spacious ? (runtime.config.mode.isServer ? 300 : 220) : 220)
                }
            }
            .workspaceCard()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.35))
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { sessionStatus; Spacer(minLength: 12); connectionActions }
                VStack(alignment: .leading, spacing: 10) { sessionStatus; connectionActions }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 20) {
                    localBinding.frame(minWidth: 180)
                    Divider().frame(height: 40)
                    endpointFields
                }
                endpointFields
            }
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
        }.padding(16)
    }

    private var sessionStatus: some View {
        HStack(spacing: 14) {
            Image(systemName: runtime.config.mode.isUDP ? "paperplane" : runtime.config.mode.isServer ? "server.rack" : "arrow.up.right.square")
                .font(.system(size: 28, weight: .medium)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(runtime.config.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Button(action: onEdit) {
                        Label(app.t("edit"), systemImage: "square.and.pencil")
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(runtime.isConfigurationLocked).accessibilityIdentifier("editSession")
                    .help(app.t("edit"))
                }
                HStack(spacing: 12) {
                    status
                    Text(runtime.config.mode.title + (runtime.config.tlsEnabled ? " · TLS" : "")).font(.callout).foregroundStyle(.secondary)
                    if runtime.isConfigurationLocked {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help(app.t("error.activeSession"))
                            .accessibilityLabel(app.t("error.activeSession"))
                    }
                }
            }
        }
    }

    private var connectionActions: some View {
        HStack(spacing: 10) {
            connectionButton
            Menu {
                Section(app.t("statistics")) {
                    Text("\(app.t("packetCounts")): TX \(runtime.sentPackets) · RX \(runtime.receivedPackets)")
                    if !runtime.config.mode.isUDP {
                        Text("\(app.t("connectedDuration")): \(Int(runtime.connectedDuration)) \(app.t("seconds"))")
                    }
                }
                if runtime.config.mode.isServer {
                    Button(action: { showClients = true }) {
                        Label(app.t(runtime.config.mode.isUDP ? "sources" : "clients"), systemImage: "person.2")
                    }
                }
                Text(app.t(runtime.config.mode.isUDP ? "udpHint" : "tcpStreamHint"))
            } label: { Label(app.t("sessionDetails"), systemImage: "ellipsis") }
            .labelStyle(.iconOnly).menuIndicator(.hidden)
            .accessibilityIdentifier("sessionDetails")
        }.controlSize(.large)
    }

    private var localBinding: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.t("localHostSummary")).font(.caption).foregroundStyle(.secondary)
                Text(!runtime.config.mode.isUDP || runtime.config.localHost.isEmpty ? app.t("automaticAddress") : runtime.config.localHost)
                    .lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !runtime.config.mode.isServer {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.t("bindPort")).font(.caption).foregroundStyle(.secondary)
                    Text(!runtime.config.mode.isUDP || runtime.config.localPort == 0 ? app.t("automaticPort") : String(runtime.config.localPort))
                }
            }
        }
        .font(.body.monospaced()).textSelection(.enabled)
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
                .font(.callout)
            if runtime.state == .reconnecting || runtime.state == .connecting || runtime.state == .starting || runtime.state == .stopping { ProgressView().controlSize(.small) }
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
        .tint(runtime.state.isActive ? .red : .accentColor)
        .disabled(runtime.state == .stopping || (runtime.isConfigurationLocked && !runtime.state.isActive))
        .keyboardShortcut("k", modifiers: .command).accessibilityIdentifier("toggleConnection")
    }
}

private extension View {
    func workspaceCard() -> some View {
        self.background(.background, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 0.5))
    }
}
