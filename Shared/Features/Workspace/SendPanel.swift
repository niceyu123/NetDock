import SwiftUI
import NetDockCore

struct SendPanel: View {
    @Environment(AppModel.self) private var app
    @Bindable var runtime: SessionRuntime
    var showClients: () -> Void
    @State private var showLoop = false
    @State private var showCommands = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Picker(app.t("sendEncoding"), selection: encodingBinding) {
                Text(app.t("utf8")).tag(DataEncoding.utf8)
                Text("HEX").tag(DataEncoding.hex)
            }.pickerStyle(.segmented).accessibilityIdentifier("sendEncoding")
            TextEditor(text: $runtime.payload)
                .font(.body.monospaced()).autocorrectionDisabled()
                .frame(minHeight: 64, idealHeight: 90, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
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
            HStack {
                Button { showLoop = true } label: { Label(app.t("periodicSend"), systemImage: "repeat") }
                    .accessibilityIdentifier("periodicSend")
                Spacer()
                Button { showCommands = true } label: { Label(app.t("commands"), systemImage: "text.badge.star") }
                    .accessibilityIdentifier("commands")
            }.font(.caption)
            if runtime.periodic.state == .running || runtime.periodic.state == .paused {
                HStack {
                    Text("\(app.t("sentCount")): \(runtime.periodic.sentCount)").font(.caption.monospaced())
                    Spacer()
                    Button(app.t("stop"), role: .destructive) { runtime.periodic.stop() }.accessibilityIdentifier("stopRepeatInline")
                }
            }
            #if os(macOS)
            Text(app.t("sendHint")).font(.caption).foregroundStyle(.secondary)
            #endif
        }
        .sheet(isPresented: $showLoop) { SendOptionsView(runtime: runtime) }
        .sheet(isPresented: $showCommands) { CommandsView(runtime: runtime) }
    }
    private var payloadSize: Int { (try? PayloadCodec.encode(runtime.payload, as: runtime.config.sendEncoding).count) ?? 0 }
    private var encodingBinding: Binding<DataEncoding> {
        Binding(get: { runtime.config.sendEncoding }, set: {
            var config = runtime.config; config.sendEncoding = $0; app.save(config)
        })
    }
}
