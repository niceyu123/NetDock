import SwiftUI
import NetDockCore

struct SendPanel: View {
    @Environment(AppModel.self) private var app
    @Bindable var runtime: SessionRuntime
    var showClients: () -> Void
    @State private var showCommands = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { panelHeading; Spacer(minLength: 8); editorActions }
                VStack(alignment: .leading, spacing: 8) {
                    panelHeading
                    HStack { editorActions; Spacer(minLength: 0) }
                }
            }
            if runtime.config.mode.isServer {
                Button(action: showClients) {
                    Label("\(app.t(runtime.config.mode.isUDP ? "sources" : "clients")) (\(runtime.peers.count))", systemImage: "person.2")
                }.accessibilityIdentifier("showClients")
                Picker(app.t("sendTo"), selection: $runtime.target) {
                    Text(app.t(runtime.config.mode.isUDP ? "selectSource" : "allClients")).tag(Optional<UUID>.none)
                    ForEach(runtime.peers) { peer in Text(peer.endpoint).tag(Optional(peer.id)) }
                    if let id = runtime.target, !runtime.peers.contains(where: { $0.id == id }) {
                        Text(app.t("error.peerMissing")).tag(Optional(id))
                    }
                }.accessibilityIdentifier("sendTarget")
                if runtime.config.mode.isUDP {
                    Toggle(app.t("explicitDestination"), isOn: $runtime.explicitUDPTarget)
                        .accessibilityIdentifier("explicitDestination")
                    if runtime.explicitUDPTarget {
                        TextField(app.t("host"), text: $runtime.destinationHost).autocorrectionDisabled()
                            .accessibilityIdentifier("destinationHost")
                        TextField(app.t("remotePort"), text: $runtime.destinationPort).monospaced()
                            .accessibilityIdentifier("destinationPort")
                    }
                }
            }
            TextEditor(text: $runtime.payload)
                .font(.body.monospaced()).autocorrectionDisabled()
                .frame(height: 72)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel(app.t("payload")).accessibilityIdentifier("payload")
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            HStack {
                Text("\(payloadSize) B").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await runtime.send() }
                } label: {
                    Label(app.t(runtime.config.mode == .tcpServer && runtime.target == nil ? "broadcast" : "send"), systemImage: "paperplane.fill")
                        .lineLimit(2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!runtime.canSend || runtime.payload.isEmpty)
                .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("sendPayload")
            }
            PeriodicSendControls(runtime: runtime)
        }
        .sheet(isPresented: $showCommands) { CommandsView(runtime: runtime) }
    }
    private var panelHeading: some View {
        HStack(spacing: 20) {
            Text(app.t("sendData")).font(.headline).foregroundStyle(.tint)
            Button { showCommands = true } label: { Text(app.t("commands")) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityIdentifier("commands")
        }
    }

    private var editorActions: some View {
        HStack(spacing: 8) {
            Picker(app.t("sendEncoding"), selection: encodingBinding) {
                Text("UTF-8").tag(DataEncoding.utf8)
                Text("HEX").tag(DataEncoding.hex)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            .accessibilityLabel(app.t("sendEncoding")).accessibilityIdentifier("sendEncoding")
            Button(app.t("clearPayload")) { runtime.payload = "" }
                .disabled(runtime.payload.isEmpty).accessibilityIdentifier("clearPayload")
        }
    }

    private var payloadSize: Int { (try? PayloadCodec.encode(runtime.payload, as: runtime.config.sendEncoding).count) ?? 0 }
    private var encodingBinding: Binding<DataEncoding> {
        Binding(get: { runtime.config.sendEncoding }, set: {
            var config = runtime.config; config.sendEncoding = $0; app.save(config)
        })
    }
}
