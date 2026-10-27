import Foundation
import Network

/// Datagram transport. NW objects and mutable state live on one serial queue.
/// Ready describes local API readiness and never implies a live remote peer.
public final class UDPService: TransportService, @unchecked Sendable {
    private final class Flow {
        let id = UUID()
        let connection: NWConnection
        var info: PeerInfo?
        var lastUsed = Date.now
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private struct Pending {
        let flowID: UUID
        let data: Data
        let continuation: CheckedContinuation<[SendOutcome], any Error>
        let timeout: DispatchWorkItem
        var submitted = false
    }
    private let mode: SessionMode
    private let operationTimeout: TimeInterval
    private let sink: @Sendable (NetworkEvent) -> Void
    private let queue = DispatchQueue(label: "org.netdock.udp.\(UUID())", qos: .userInitiated)
    private var state: ConnectionState = .idle
    private var config: SessionConfig?
    private var listener: NWListener?
    private var generation = UUID()
    private var flows: [UUID: Flow] = [:]
    private var pending: [UUID: Pending] = [:]
    private var pendingBytes = 0
    private var startupTimeout: DispatchWorkItem?
    private var closing = 0
    private var cleanupWaiters: [@Sendable () -> Void] = []
    private let maxFlows = 128
    private let maxPendingBytes = 4 * 1_024 * 1_024

    public init(mode: SessionMode, operationTimeout: TimeInterval = 10,
                onEvent: @escaping @Sendable (NetworkEvent) -> Void) {
        self.mode = mode; self.operationTimeout = max(0.1, operationTimeout); sink = onEvent
    }
    public func start(_ config: SessionConfig) async throws {
        let valid = try config.validated()
        guard valid.mode == mode, mode.isUDP else { throw NetDockError(.unsupportedMode) }
        await waitForCleanup()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !state.isActive else { continuation.resume(); return }
                self.config = valid; generation = UUID(); let token = generation
                transition(.starting); sink(.system("event.started"))
                do {
                    if mode == .udpClient {
                        let connection = try makeConnection(host: valid.host, port: valid.remotePort)
                        add(connection, token: token)
                    } else {
                        let parameters = NWParameters.udp
                        if !valid.localHost.isEmpty {
                            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(valid.localHost), port: NWEndpoint.Port(rawValue: valid.localPort) ?? .any)
                        }
                        let listener: NWListener
                        if valid.localHost.isEmpty {
                            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: valid.localPort) ?? .any)
                        } else {
                            // requiredLocalEndpoint already supplies address AND port. Supplying
                            // another port through the convenience initializer returns EINVAL.
                            listener = try NWListener(using: parameters)
                        }
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self, weak listener] status in
                            guard let self, self.generation == token else { return }
                            switch status {
                            case .ready:
                                self.startupTimeout?.cancel(); self.startupTimeout = nil
                                self.transition(.listening)
                                if let port = listener?.port {
                                    self.sink(.listening(port: port.rawValue))
                                    self.sink(.localEndpoint(Self.format(host: valid.localHost.isEmpty ? "*" : valid.localHost, port: port.rawValue)))
                                }
                                self.sink(.system("event.listening"))
                            case .failed(let error), .waiting(let error): self.fail(Self.describe(error))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self, self.generation == token, self.state == .listening else { connection.cancel(); return }
                            self.makeRoom(); self.add(connection, token: token)
                        }
                        listener.start(queue: queue)
                    }
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == token, self.state == .starting else { return }
                        self.fail(NetDockError(.timeout))
                    }
                    startupTimeout = timeout; queue.asyncAfter(deadline: .now() + operationTimeout, execute: timeout)
                    continuation.resume()
                } catch {
                    let problem = (error as? NetDockError) ?? Self.describe(error)
                    fail(problem); continuation.resume(throwing: problem)
                }
            }
        }
    }
    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if state == .stopping || !state.isActive {
                    if closing > 0 { cleanupWaiters.append { continuation.resume() } }
                    else { continuation.resume() }
                    return
                }
                transition(.stopping)
                cleanup { [self] in
                    transition(.stopped); sink(.system("event.userStopped")); continuation.resume()
                }
            }
        }
    }
    /// UDP forgets a remembered source; there is no remote disconnect handshake.
    public func disconnect(peerID: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in remove(peerID); continuation.resume() }
        }
    }
    public func send(_ data: Data, to target: SendTarget = .remote) async throws -> [SendOutcome] {
        guard !data.isEmpty else { throw NetDockError(.emptyPayload) }
        guard data.count <= 65_507 else { throw NetDockError(.datagramTooLarge) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard mode.isServer ? state == .listening : state == .ready else { throw NetDockError(.notReady) }
                    guard pending.count < 128, pendingBytes <= maxPendingBytes - data.count else { throw NetDockError(.sendQueueFull) }
                    let flow: Flow
                    switch target {
                    case .remote:
                        guard mode == .udpClient, let client = flows.values.first else { throw NetDockError(.notReady) }
                        flow = client
                    case .peer(let id):
                        guard mode == .udpServer, let peer = flows[id], peer.info != nil else { throw NetDockError(.peerMissing) }
                        flow = peer
                    case .endpoint(let host, let port):
                        guard mode == .udpServer, port > 0 else { throw NetDockError(.invalidPort) }
                        let host = try EndpointInput.unicastHost(host)
                        let endpoint = Self.format(host: host, port: port)
                        if let existing = flows.values.first(where: { $0.info?.endpoint == endpoint || Self.endpoint($0.connection.endpoint) == endpoint }) {
                            flow = existing
                        } else {
                            makeRoom()
                            let connection = try makeConnection(host: host, port: port)
                            flow = add(connection, token: generation)
                        }
                    case .allPeers: throw NetDockError(.unsupportedMode)
                    }
                    flow.lastUsed = .now
                    let id = UUID()
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self, let send = self.pending[id] else { return }
                        self.finish(id, error: NetDockError(.timeout))
                        if self.mode == .udpServer { self.remove(send.flowID) } else { self.fail(NetDockError(.timeout)) }
                    }
                    pending[id] = Pending(flowID: flow.id, data: data, continuation: continuation, timeout: timeout)
                    pendingBytes += data.count
                    queue.asyncAfter(deadline: .now() + operationTimeout, execute: timeout)
                    submit(id)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func makeConnection(host: String, port: UInt16) throws -> NWConnection {
        guard let config, let port = NWEndpoint.Port(rawValue: port) else { throw NetDockError(.invalidPort) }
        let parameters = NWParameters.udp
        if config.localPort != 0 || !config.localHost.isEmpty {
            let localHost = config.localHost.isEmpty ? (IPv6Address(host) != nil ? "::" : "0.0.0.0") : config.localHost
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localHost), port: NWEndpoint.Port(rawValue: config.localPort) ?? .any)
            // Network.framework shares the server listener's local UDP port for outbound flows.
            // The listener itself never enables reuse, so a second server still fails EADDRINUSE.
            parameters.allowLocalEndpointReuse = mode == .udpServer
        }
        return NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    }
    @discardableResult private func add(_ connection: NWConnection, token: UUID) -> Flow {
        let flow = Flow(connection); let id = flow.id; flows[id] = flow
        connection.stateUpdateHandler = { [weak self] status in
            guard let self, self.generation == token, let flow = self.flows[id] else { return }
            switch status {
            case .ready:
                guard flow.info == nil else { return }
                flow.info = PeerInfo(id: id, endpoint: Self.endpoint(connection.currentPath?.remoteEndpoint ?? connection.endpoint),
                    localEndpoint: connection.currentPath?.localEndpoint.map(Self.endpoint), connectedAt: .now)
                if self.mode == .udpClient {
                    self.startupTimeout?.cancel(); self.startupTimeout = nil
                    self.transition(.ready); self.sink(.system("event.udpReady"))
                    if let local = flow.info?.localEndpoint { self.sink(.localEndpoint(local)) }
                } else if let info = flow.info { self.sink(.peerJoined(info)) }
                self.receive(id, token: token)
                for key in self.pending.filter({ $0.value.flowID == id }).map(\.key) { self.submit(key) }
            case .waiting(let error), .failed(let error):
                if self.mode == .udpClient { self.fail(Self.describe(error)) }
                else { self.sink(.error(Self.describe(error))); self.remove(id) }
            default: break
            }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            guard let self, self.generation == token, !viable, self.flows[id]?.info != nil else { return }
            if self.mode == .udpClient { self.fail(NetDockError(.network)) }
            else { self.remove(id) }
        }
        connection.start(queue: queue)
        return flow
    }
    private func receive(_ id: UUID, token: UUID) {
        guard let flow = flows[id] else { return }
        flow.connection.receiveMessage { [weak self] data, _, complete, error in
            guard let self, self.generation == token, let flow = self.flows[id], let info = flow.info else { return }
            if let error {
                if self.mode == .udpClient { self.fail(Self.describe(error)) }
                else { self.sink(.error(Self.describe(error))); self.remove(id) }
                return
            }
            if complete {
                flow.lastUsed = .now
                // UDP's complete flag ends this datagram, never the flow. Empty datagrams are valid RX.
                self.sink(.received(Transfer(timestamp: .now, payload: data ?? Data(), peerID: self.mode.isServer ? id : nil,
                    remoteEndpoint: info.endpoint, localEndpoint: info.localEndpoint)))
            } else {
                self.sink(.error(NetDockError(.datagramTooLarge)))
            }
            self.receive(id, token: token)
        }
    }
    private func submit(_ id: UUID) {
        guard var send = pending[id], !send.submitted, let flow = flows[send.flowID], flow.info != nil else { return }
        send.submitted = true; pending[id] = send
        flow.connection.send(content: send.data, contentContext: .defaultMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in self?.finish(id, error: error.map(Self.describe)) })
    }
    private func finish(_ id: UUID, error: NetDockError?) {
        guard let send = pending.removeValue(forKey: id) else { return }
        pendingBytes -= send.data.count; send.timeout.cancel()
        let flow = flows[send.flowID]
        let endpoint = flow?.info?.endpoint ?? flow.map { Self.endpoint($0.connection.endpoint) } ?? ""
        let transfer = Transfer(timestamp: .now, payload: send.data, peerID: mode.isServer ? send.flowID : nil,
            remoteEndpoint: endpoint, localEndpoint: flow?.info?.localEndpoint)
        sink(.sendResult(transfer, error))
        send.continuation.resume(returning: [SendOutcome(peerID: transfer.peerID, endpoint: endpoint, error: error)])
    }
    private func makeRoom() {
        if flows.count >= maxFlows, let oldest = flows.values.min(by: { $0.lastUsed < $1.lastUsed }) { remove(oldest.id) }
    }
    private func remove(_ id: UUID) {
        guard let flow = flows[id] else { return }
        for key in pending.filter({ $0.value.flowID == id }).map(\.key) { finish(key, error: NetDockError(.notReady)) }
        flows.removeValue(forKey: id)
        if mode.isServer, flow.info != nil { sink(.peerLeft(id)) }
        flow.connection.stateUpdateHandler = nil; flow.connection.viabilityUpdateHandler = nil; flow.connection.cancel()
    }
    private func transition(_ state: ConnectionState) { self.state = state; sink(.stateChanged(state)) }
    private func fail(_ error: NetDockError) { cleanup(); transition(.failed); sink(.error(error)) }
    private func waitForCleanup() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if closing > 0 { cleanupWaiters.append { continuation.resume() } } else { continuation.resume() }
            }
        }
    }
    private func cleanup(completion: (@Sendable () -> Void)? = nil) {
        generation = UUID(); startupTimeout?.cancel(); startupTimeout = nil
        for id in Array(pending.keys) { finish(id, error: NetDockError(.notReady)) }
        if let completion { cleanupWaiters.append(completion) }
        let connections = flows.values.map(\.connection)
        for flow in flows.values where mode.isServer && flow.info != nil { sink(.peerLeft(flow.id)) }
        flows.removeAll()
        closing += connections.count + (listener == nil ? 0 : 1)
        for connection in connections {
            connection.viabilityUpdateHandler = nil
            connection.stateUpdateHandler = { [weak self] status in if case .cancelled = status { self?.closed() } }
            connection.cancel()
        }
        if let listener {
            self.listener = nil; listener.newConnectionHandler = nil
            listener.stateUpdateHandler = { [weak self] status in if case .cancelled = status { self?.closed() } }
            listener.cancel()
        }
        finishCleanup()
    }
    private func closed() { closing -= 1; finishCleanup() }
    private func finishCleanup() {
        guard closing == 0 else { return }
        let waiters = cleanupWaiters; cleanupWaiters.removeAll()
        for waiter in waiters { waiter() }
    }
    private static func format(host: String, port: UInt16) -> String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }
    private static func endpoint(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, let port) = endpoint { return format(host: String(describing: host), port: port.rawValue) }
        return String(describing: endpoint)
    }
    private static func describe(_ error: any Error) -> NetDockError {
        let code: NetDockError.Code
        switch error as? NWError {
        case .posix(.EADDRINUSE): code = .addressInUse
        case .posix(.EACCES), .posix(.EPERM): code = .permissionDenied
        case .posix(.ETIMEDOUT): code = .timeout
        case .posix(.ECONNREFUSED): code = .refused
        case .posix(.EMSGSIZE): code = .datagramTooLarge
        default: code = .network
        }
        return NetDockError(code, detail: String(describing: error))
    }
    deinit {
        startupTimeout?.cancel(); listener?.stateUpdateHandler = nil; listener?.cancel()
        for flow in flows.values { flow.connection.stateUpdateHandler = nil; flow.connection.cancel() }
        for send in pending.values { send.timeout.cancel(); send.continuation.resume(throwing: NetDockError(.notReady)) }
    }
}
