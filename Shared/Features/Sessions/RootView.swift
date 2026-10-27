import SwiftUI
import NetDockCore

struct RootView: View {
    private enum SidebarSelection: Hashable {
        case session(UUID)
        #if os(macOS)
        case monitor
        #endif
    }
    @Environment(AppModel.self) private var app
    @State private var selection: SidebarSelection?
    @State private var editing: SessionConfig?
    @State private var showSettings = false
    @State private var creating: SessionConfig?
    @State private var showTransfer = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $selection) {
                Section(app.t("tools")) {
                    ForEach(SessionMode.allCases, id: \.self) { mode in
                        Button { createSession(mode) } label: {
                            Label {
                                Text(mode.title).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: sidebarSymbol(for: mode)).foregroundStyle(.tint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("newSession.\(mode.rawValue)")
                    }
                    #if os(macOS)
                    NavigationLink(value: SidebarSelection.monitor) {
                        Label(app.t("connectionMonitor"), systemImage: "network")
                            .padding(.vertical, 5)
                    }
                    .accessibilityIdentifier("connectionMonitor")
                    #endif
                }
                Section(app.t("sessions")) {
                    if app.sessions.isEmpty {
                        Text(app.t("noSessions")).font(.callout).foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    }
                    ForEach(app.sessions) { config in
                        NavigationLink(value: SidebarSelection.session(config.id)) {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(config.name).fontWeight(.medium).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if let runtime = app.sessionManager.runtimes[config.id] {
                                            Text(app.t(config.mode.stateKey(runtime.state)))
                                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Text("\(config.mode.title) · \(config.endpointDescription)")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }.padding(.vertical, 5)
                            } icon: {
                                Image(systemName: sidebarSymbol(for: config.mode))
                            }
                        }
                        .accessibilityIdentifier("sessionRow.\(config.id)")
                        .contextMenu {
                            Button(app.t("edit")) { editing = config }
                                .disabled(app.sessionManager.runtimes[config.id]?.isConfigurationLocked == true)
                            if let runtime = app.sessionManager.runtimes[config.id] {
                                Button(app.t(runtime.state.isActive ? (config.mode.isUDP ? "stopSession" : config.mode.isServer ? "stopListening" : "disconnect") :
                                             (config.mode.isUDP ? "startSession" : config.mode.isServer ? "startListening" : "connect"))) {
                                    Task {
                                        if runtime.state.isActive { await runtime.stop() }
                                        else if !(await app.startSession(runtime)) { selection = .session(config.id) }
                                    }
                                }
                                .accessibilityIdentifier("toggleSession.\(config.id)")
                            }
                            Button(app.t("duplicate")) { app.duplicate(config) }
                            Button(app.t("delete"), role: .destructive) {
                                app.delete(config.id); if selection == .session(config.id) { selection = nil }
                            }
                        }
                    }
                    .onDelete { indices in
                        for id in indices.map({ app.sessions[$0].id }) { app.delete(id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("NetDock")
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
            .toolbar {
                ToolbarItem {
                    Button { showTransfer = true } label: { Label(app.t("configurationTransfer"), systemImage: "square.and.arrow.up.on.square") }
                        .accessibilityIdentifier("sessionTransfer")
                }
                ToolbarItem {
                    Button { showSettings = true } label: {
                        Label(app.t("settings"), systemImage: "gearshape")
                    }.accessibilityIdentifier("settings")
                }
            }
        } detail: {
            #if os(macOS)
            if selection == .monitor { ConnectionMonitorView() } else { sessionDetail }
            #else
            sessionDetail
            #endif
        }
        .sheet(isPresented: $showTransfer) { SessionTransferView() }
        .focusedSceneValue(\.newSessionAction, { createSession(.tcpClient) })
        .sheet(item: $creating) { draft in
            SessionEditor(config: draft) { config in
                guard app.save(config) else { return false }
                selection = .session(config.id)
                return true
            }
        }
        .sheet(item: $editing) { config in SessionEditor(config: config) { app.save($0) } }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(app.t("done")) { showSettings = false }.accessibilityIdentifier("closeSettings")
                    }
                }
            }
            #if os(macOS)
            .frame(width: 510, height: 510)
            #endif
        }
        .alert(app.t("storageNotice"), isPresented: Binding(get: { app.storageError != nil }, set: { if !$0 { app.storageError = nil } })) {
            Button(app.t("done")) { app.storageError = nil }
        } message: { Text(app.storageError.map(app.errorText) ?? "") }
        .environment(\.locale, Locale(identifier: app.language.rawValue))
        .preferredColorScheme(app.appearance.colorScheme)
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await app.sessionManager.stopAllForBackground() } }
        }
        #endif
    }

    private func createSession(_ mode: SessionMode) {
        creating = SessionConfig(name: app.t("untitledSession"), mode: mode,
                                 localPort: mode == .udpClient ? 0 : 9000)
    }

    private func sidebarSymbol(for mode: SessionMode) -> String {
        switch mode {
        case .tcpClient: "arrow.up.right.square"
        case .tcpServer: "server.rack"
        case .udpClient: "paperplane"
        case .udpServer: "tray.and.arrow.down"
        }
    }

    @ViewBuilder private var sessionDetail: some View {
            if case let .session(id)? = selection,
               let config = app.sessions.first(where: { $0.id == id }) {
                if let runtime = app.sessionManager.runtimes[config.id] {
                    WorkspaceView(runtime: runtime, onEdit: { editing = config }).id(config.id)
                }
            } else {
                ContentUnavailableView(app.t("selectSession"), systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(app.t("workspaceHint")))
            }
    }
}
