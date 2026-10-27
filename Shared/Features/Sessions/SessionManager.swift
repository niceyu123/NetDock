import SwiftUI
import NetDockCore

struct SendHistoryEntry: Identifiable {
    let id = UUID()
    let text: String
    let encoding: DataEncoding
}

@MainActor @Observable
final class SessionRuntime {
    var history: [SendHistoryEntry] = []
    let periodic = PeriodicSender()
    var intervalText = "1000"
    var continuous = true
    var repeatCountText = "10"
    var config: SessionConfig
    var endpointHost: String
    var endpointPort: String
    var endpointError: NetDockError?
    var state: ConnectionState = .idle
    var records: [TrafficRecord] = []
    var peers: [PeerInfo] = []
    var sentBytes: UInt64 = 0
    var receivedBytes: UInt64 = 0
    var lastError: NetDockError?
    var inputError: NetDockError?
    var payload = ""
    var target: UUID? // nil explicitly means all connected clients for a server.
    var isSending = false
    var explicitUDPTarget = false
    var destinationHost = "127.0.0.1"
    var destinationPort = "9000"
    var localEndpoint: String?
    var sentPackets: UInt64 = 0
    var receivedPackets: UInt64 = 0
    var connectedDuration: TimeInterval = 0
    private let traffic: SessionTrafficStore
    private let transport: any TransportService
    private var wantsRunning = false
    private var isStarting = false

    var isConfigurationLocked: Bool { state.isActive || isStarting }
    var isEndpointDirty: Bool {
        endpointPort != String(config.mode.isServer ? config.localPort : config.remotePort) ||
        (!config.mode.isServer && endpointHost != config.host)
    }

    init(config: SessionConfig) {
        self.config = config
        endpointHost = config.host
        endpointPort = String(config.mode.isServer ? config.localPort : config.remotePort)
        intervalText = String(format: "%g", config.repeatInterval * 1000)
        continuous = config.repeatCount == 0
        repeatCountText = String(config.repeatCount == 0 ? 10 : config.repeatCount)
        let traffic = SessionTrafficStore(sessionID: config.id, mode: config.mode)
        self.traffic = traffic
        transport = config.mode.isUDP ? UDPService(mode: config.mode) { traffic.ingest($0) } : TCPService(mode: config.mode) { traffic.ingest($0) }
    }

    var canSend: Bool {
        periodic.state != .running && !isSending && (config.mode == .udpServer ? state == .listening && (explicitUDPTarget || target != nil) : config.mode == .tcpServer ? state == .listening && !peers.isEmpty : state == .ready)
    }
    func resetEndpointDraft() {
        endpointHost = config.host
        endpointPort = String(config.mode.isServer ? config.localPort : config.remotePort)
        endpointError = nil
    }
    func refresh() {
        guard let snapshot = traffic.takeSnapshot() else { return }
        state = snapshot.state; records = snapshot.records; peers = snapshot.peers
        localEndpoint = snapshot.localEndpoint; sentPackets = snapshot.sentPackets; receivedPackets = snapshot.receivedPackets
        connectedDuration = snapshot.connectedDuration
        sentBytes = snapshot.sentBytes; receivedBytes = snapshot.receivedBytes; lastError = snapshot.lastError
        if [.stopped, .failed, .stopping].contains(state) { periodic.stop() }
        // Preserve a disconnected selection: never silently redirect a targeted send to broadcast.
    }
    func start() async {
        guard !isStarting, !state.isActive else { return }
        isStarting = true
        defer { isStarting = false }
        wantsRunning = true
        inputError = nil
        do { try await transport.start(config) }
        catch { inputError = (error as? NetDockError) ?? NetDockError(.network) }
        // A background/stop request can arrive while startup is suspended.
        if !wantsRunning { await transport.stop() }
        refresh()
    }
    func stop(background: Bool = false) async {
        wantsRunning = false
        periodic.stop()
        await transport.stop()
        await periodic.waitUntilIdle()
        if background { traffic.ingest(.system("event.background")) }
        refresh()
    }
    func send() async {
        guard !isSending else { return }
        do {
            let data = try PayloadCodec.encode(payload, as: config.sendEncoding)
            inputError = nil; isSending = true
            defer { isSending = false; refresh() }
            let destination = try sendTarget()
            let outcomes = try await transport.send(data, to: destination)
            if let error = outcomes.compactMap(\.error).first { throw error }
            remember(payload, encoding: config.sendEncoding)
        } catch { inputError = (error as? NetDockError) ?? NetDockError(.network) }
    }
    func startPeriodic() {
        do {
            guard canSend else { throw NetDockError(.notReady) }
            let data = try PayloadCodec.encode(payload, as: config.sendEncoding)
            let target = try sendTarget()
            guard let milliseconds = Double(intervalText), milliseconds.isFinite else { throw NetDockError(.invalidInterval) }
            let total: Int?
            if continuous { total = nil }
            else {
                guard let count = Int(repeatCountText), count > 0 else { throw NetDockError(.invalidRepeatCount) }
                total = count
            }
            let service = transport
            try periodic.start(interval: milliseconds / 1000, total: total) {
                let outcomes = try await service.send(data, to: target)
                if let error = outcomes.compactMap(\.error).first { throw error }
            }
            inputError = nil; remember(payload, encoding: config.sendEncoding)
        } catch { inputError = (error as? NetDockError) ?? NetDockError(.network) }
    }
    private func remember(_ text: String, encoding: DataEncoding) {
        guard text.utf8.count <= 65_536 else { return }
        history.removeAll { $0.text == text && $0.encoding == encoding }
        history.insert(SendHistoryEntry(text: text, encoding: encoding), at: 0)
        while history.count > 50 || history.reduce(0, { $0 + $1.text.utf8.count }) > 1_048_576 { history.removeLast() }
    }
    func sendTarget() throws -> SendTarget {
        if config.mode == .udpServer {
            if explicitUDPTarget {
                return .endpoint(host: try EndpointInput.unicastHost(destinationHost), port: try EndpointInput.port(destinationPort))
            }
            guard let target else { throw NetDockError(.peerMissing) }
            return .peer(target)
        }
        return config.mode == .tcpServer ? target.map(SendTarget.peer) ?? .allPeers : .remote
    }
    func disconnect(_ peerID: UUID) async { await transport.disconnect(peerID: peerID); refresh() }
    func clearLogs() { traffic.clear(); refresh() }
}

@MainActor @Observable
final class SessionManager {
    private(set) var runtimes: [UUID: SessionRuntime] = [:]
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    init() {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                guard let self else { break }
                for runtime in self.runtimes.values { runtime.refresh() }
            }
        }
    }
    func synchronize(_ configs: [SessionConfig]) {
        for config in configs {
            if let runtime = runtimes[config.id], runtime.config.mode == config.mode {
                let endpointChanged = runtime.config.endpointDescription != config.endpointDescription
                runtime.config = config
                if endpointChanged { runtime.resetEndpointDraft() }
            }
            else {
                if let old = runtimes[config.id] { Task { await old.stop() } }
                runtimes[config.id] = SessionRuntime(config: config)
            }
        }
    }
    func remove(_ id: UUID) {
        if let runtime = runtimes.removeValue(forKey: id) { Task { await runtime.stop() } }
    }
    func stopAllForBackground() async {
        for runtime in runtimes.values { await runtime.stop(background: true) }
    }
    deinit { updateTask?.cancel() }
}
