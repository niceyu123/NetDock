import Foundation
import Network

/// All mutable state, NW objects and callbacks are confined to `queue`.
/// Each start owns a generation token; callbacks from a stopped generation are ignored.
public final class TCPService: TransportService, @unchecked Sendable {
    private final class Peer {
        let id: UUID
        let connection: NWConnection
        var info: PeerInfo?
        init(id: UUID, connection: NWConnection) { self.id = id; self.connection = connection }
    }
    private struct PendingSend {
        let peerID: UUID
        let transfer: Transfer
        let finish: @Sendable (SendOutcome) -> Void
    }
    private final class Batch: @unchecked Sendable {
        // Accessed only on the owning TCPService queue.
        var remaining: Int
        var outcomes: [SendOutcome] = []
        let continuation: CheckedContinuation<[SendOutcome], any Error>
        init(count: Int, continuation: CheckedContinuation<[SendOutcome], any Error>) {
            remaining = count; self.continuation = continuation
        }
        func finish(_ outcome: SendOutcome) {
            outcomes.append(outcome); remaining -= 1
            if remaining == 0 { continuation.resume(returning: outcomes) }
        }
    }

    private let mode: SessionMode
    private let queue = DispatchQueue(label: "org.netdock.tcp.\(UUID())", qos: .userInitiated)
    private let sink: @Sendable (NetworkEvent) -> Void
    private let connectionTimeout: TimeInterval
    private var generation = UUID()
    private var state: ConnectionState = .idle
    private var listener: NWListener?
    private var cancellingListener: NWListener?
    private var cleanupWaiters: [@Sendable () -> Void] = []
    private var peers: [UUID: Peer] = [:]
    private var timeout: DispatchWorkItem?
    private var pending: [UUID: PendingSend] = [:]
    private var pendingBytes = 0
    private let maxPendingBytes = 16 * 1_024 * 1_024
    private let maxPeers = 128

    public init(mode: SessionMode, connectionTimeout: TimeInterval = 15,
                onEvent: @escaping @Sendable (NetworkEvent) -> Void) {
        self.mode = mode; self.connectionTimeout = max(0.1, connectionTimeout); sink = onEvent
    }

    public func start(_ config: SessionConfig) async throws {
        let valid = try config.validated()
        guard valid.mode == mode, [.tcpClient, .tcpServer].contains(mode) else { throw NetDockError(.unsupportedMode) }
        await waitForCleanup()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !state.isActive else { continuation.resume(); return }
                generation = UUID(); let token = generation
                transition(.connecting); sink(.system("event.started"))
                if mode == .tcpClient {
                    guard let port = NWEndpoint.Port(rawValue: valid.remotePort) else {
                        transition(.failed); continuation.resume(throwing: NetDockError(.invalidPort)); return
                    }
                    let connection = NWConnection(host: NWEndpoint.Host(valid.host), port: port, using: .tcp)
                    add(connection, token: token)
                    let item = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == token, self.state == .connecting else { return }
                        self.fail(NetDockError(.timeout))
                    }
                    timeout = item; queue.asyncAfter(deadline: .now() + connectionTimeout, execute: item)
                    continuation.resume()
                } else {
                    do {
                        guard let port = NWEndpoint.Port(rawValue: valid.localPort) else { throw NetDockError(.invalidPort) }
                        // Do not enable address reuse: a second active listener must fail visibly.
                        let listener = try NWListener(using: .tcp, on: port)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self, weak listener] status in
                            guard let self, self.generation == token else { return }
                            switch status {
                            case .ready:
                                self.transition(.listening)
                                if let port = listener?.port { self.sink(.listening(port: port.rawValue)) }
                                self.sink(.system("event.listening"))
                            case .failed(let error): self.fail(Self.describe(error))
                            case .waiting(let error): self.fail(Self.describe(error))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self, self.generation == token, self.state == .listening,
                                  self.peers.count < self.maxPeers else { connection.cancel(); return }
                            self.add(connection, token: token)
                        }
                        listener.start(queue: queue); continuation.resume()
                    } catch {
                        let problem = (error as? NetDockError) ?? Self.describe(error)
                        fail(problem); continuation.resume(throwing: problem)
                    }
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard state.isActive else {
                    if cancellingListener != nil { cleanupWaiters.append { continuation.resume() } }
                    else { continuation.resume() }
                    return
                }
                if state == .stopping { cleanupWaiters.append { continuation.resume() }; return }
                transition(.stopping)
                cleanup { [self] in
                    transition(.stopped); sink(.system("event.userStopped")); continuation.resume()
                }
            }
        }
    }

    public func disconnect(peerID: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                remove(peerID, reason: "event.peerLeft"); continuation.resume()
            }
        }
    }

    public func send(_ data: Data, to target: SendTarget = .remote) async throws -> [SendOutcome] {
        guard !data.isEmpty else { throw NetDockError(.emptyPayload) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let recipients: [Peer]
                switch target {
                case .endpoint:
                    continuation.resume(throwing: NetDockError(.unsupportedMode)); return
                case .remote:
                    guard mode == .tcpClient, state == .ready else {
                        continuation.resume(throwing: NetDockError(.notReady)); return
                    }
                    recipients = peers.values.filter { $0.info != nil }
                case .peer(let id):
                    guard let peer = peers[id], peer.info != nil else {
                        continuation.resume(throwing: NetDockError(.peerMissing)); return
                    }
                    recipients = [peer]
                case .allPeers: recipients = peers.values.filter { $0.info != nil }
                }
                guard !recipients.isEmpty else { continuation.resume(throwing: NetDockError(.noPeers)); return }
                guard data.count <= maxPendingBytes / recipients.count,
                      pendingBytes <= maxPendingBytes - data.count * recipients.count else {
                    continuation.resume(throwing: NetDockError(.sendQueueFull)); return
                }
                let batch = Batch(count: recipients.count, continuation: continuation)
                for peer in recipients {
                    let id = UUID()
                    let transfer = Transfer(timestamp: .now, payload: data,
                        peerID: mode.isServer ? peer.id : nil,
                        remoteEndpoint: peer.info?.endpoint ?? "", localEndpoint: peer.info?.localEndpoint)
                    pending[id] = PendingSend(peerID: peer.id, transfer: transfer, finish: { batch.finish($0) })
                    pendingBytes += data.count
                    // Queue confinement preserves the order of submitted sends per connection.
                    peer.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                        self?.finishSend(id, error: error.map(Self.describe))
                    })
                }
            }
        }
    }

    private func add(_ connection: NWConnection, token: UUID) {
        let id = UUID(); let peer = Peer(id: id, connection: connection); peers[id] = peer
        connection.stateUpdateHandler = { [weak self] status in
            guard let self, self.generation == token, let peer = self.peers[id] else { return }
            switch status {
            case .ready:
                guard peer.info == nil else { return }
                peer.info = PeerInfo(id: id, endpoint: Self.endpoint(connection.currentPath?.remoteEndpoint ?? connection.endpoint),
                                     localEndpoint: connection.currentPath?.localEndpoint.map(Self.endpoint), connectedAt: .now)
                if self.mode == .tcpClient {
                    self.timeout?.cancel(); self.timeout = nil
                    self.transition(.ready); self.sink(.system("event.connected"))
                } else if let info = peer.info { self.sink(.peerJoined(info)) }
                self.receive(id, token: token)
            case .waiting(let error), .failed(let error):
                if self.mode == .tcpClient { self.fail(Self.describe(error)) }
                else { self.sink(.error(Self.describe(error))); self.remove(id, reason: "event.peerLeft") }
            case .cancelled: self.remove(id, reason: "event.peerLeft")
            default: break
            }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            guard let self, self.generation == token, !viable, self.peers[id]?.info != nil else { return }
            if self.mode == .tcpClient { self.fail(NetDockError(.network, detail: "Network path is no longer viable")) }
            else { self.remove(id, reason: "event.networkUnavailable") }
        }
        connection.start(queue: queue)
    }

    private func receive(_ id: UUID, token: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self, self.generation == token, let peer = self.peers[id], let info = peer.info else { return }
            if let data, !data.isEmpty {
                peer.info?.bytesReceived &+= UInt64(data.count)
                self.sink(.received(Transfer(timestamp: .now, payload: data, peerID: self.mode.isServer ? id : nil,
                                             remoteEndpoint: info.endpoint, localEndpoint: info.localEndpoint)))
            }
            if let error {
                if self.mode == .tcpClient { self.fail(Self.describe(error)) }
                else { self.sink(.error(Self.describe(error))); self.remove(id, reason: "event.peerLeft") }
            } else if complete {
                if self.mode == .tcpClient {
                    self.cleanup(); self.transition(.stopped); self.sink(.system("event.remoteClosed"))
                } else { self.remove(id, reason: "event.remoteClosed") }
            } else { self.receive(id, token: token) }
        }
    }

    private func finishSend(_ id: UUID, error: NetDockError?) {
        guard let send = pending.removeValue(forKey: id) else { return }
        pendingBytes -= send.transfer.payload.count
        if error == nil { peers[send.peerID]?.info?.bytesSent &+= UInt64(send.transfer.payload.count) }
        sink(.sendResult(send.transfer, error))
        send.finish(SendOutcome(peerID: send.transfer.peerID, endpoint: send.transfer.remoteEndpoint, error: error))
    }

    private func remove(_ id: UUID, reason: String) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        for key in pending.filter({ $0.value.peerID == id }).map(\.key) { finishSend(key, error: NetDockError(.notReady)) }
        peer.connection.stateUpdateHandler = nil; peer.connection.viabilityUpdateHandler = nil; peer.connection.cancel()
        if mode.isServer, peer.info != nil {
            sink(.peerLeft(id))
            if reason != "event.peerLeft" { sink(.system(reason)) }
        }
    }
    private func transition(_ next: ConnectionState) { state = next; sink(.stateChanged(next)) }
    private func fail(_ error: NetDockError) { cleanup(); transition(.failed); sink(.error(error)) }
    private func waitForCleanup() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if cancellingListener != nil { cleanupWaiters.append { continuation.resume() } }
                else { continuation.resume() }
            }
        }
    }
    private func cleanup(completion: (@Sendable () -> Void)? = nil) {
        generation = UUID(); timeout?.cancel(); timeout = nil
        for id in Array(peers.keys) { remove(id, reason: "event.peerLeft") }
        if let listener {
            self.listener = nil; cancellingListener = listener
            if let completion { cleanupWaiters.append(completion) }
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, case .cancelled = state else { return }
                self.cancellingListener = nil
                let waiters = self.cleanupWaiters; self.cleanupWaiters.removeAll()
                for waiter in waiters { waiter() }
            }
            listener.cancel()
        } else if cancellingListener != nil {
            if let completion { cleanupWaiters.append(completion) }
        } else { completion?() }
    }
    private static func endpoint(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, let port) = endpoint {
            let host = String(describing: host)
            return "\(host.contains(":") ? "[\(host)]" : host):\(port.rawValue)"
        }
        return String(describing: endpoint)
    }
    private static func describe(_ error: any Error) -> NetDockError {
        guard let error = error as? NWError else { return NetDockError(.network, detail: String(describing: error)) }
        let code: NetDockError.Code
        switch error {
        case .posix(.ECONNREFUSED): code = .refused
        case .posix(.EADDRINUSE): code = .addressInUse
        case .posix(.EACCES), .posix(.EPERM): code = .permissionDenied
        case .posix(.ETIMEDOUT): code = .timeout
        case .dns: code = .dns
        default: code = .network
        }
        return NetDockError(code, detail: String(describing: error))
    }

    deinit {
        timeout?.cancel(); listener?.stateUpdateHandler = nil; listener?.cancel()
        cancellingListener?.stateUpdateHandler = nil; cancellingListener?.cancel()
        for peer in peers.values { peer.connection.cancel() }
        for send in pending.values {
            send.finish(SendOutcome(peerID: send.transfer.peerID, endpoint: send.transfer.remoteEndpoint, error: NetDockError(.notReady)))
        }
    }
}
