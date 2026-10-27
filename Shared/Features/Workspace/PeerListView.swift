import SwiftUI
import NetDockCore

struct PeerListView: View {
    @Environment(AppModel.self) private var app
    @Bindable var runtime: SessionRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(app.t(runtime.config.mode.isUDP ? "sources" : "clients")) (\(runtime.peers.count))", systemImage: "person.2").font(.headline)
            if runtime.peers.isEmpty {
                Text(app.t(runtime.config.mode.isUDP ? "noSourcesHint" : "noClientsHint")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(runtime.peers) { peer in
                VStack(alignment: .leading, spacing: 6) {
                    Label(peer.endpoint, systemImage: "checkmark.circle.fill")
                        .font(.callout.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
                    Text("TX \(peer.bytesSent) · RX \(peer.bytesReceived) B")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(app.t(runtime.config.mode.isUDP ? "udpSource" : "state.\(peer.state.rawValue)")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(app.t(runtime.config.mode.isUDP ? "replySource" : "sendTo")) { runtime.target = peer.id; runtime.explicitUDPTarget = false }
                        Spacer()
                        Button(app.t(runtime.config.mode.isUDP ? "forgetSource" : "disconnect"), role: .destructive) { Task { await runtime.disconnect(peer.id) } }
                    }.buttonStyle(.bordered)
                }.padding(.vertical, 6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
