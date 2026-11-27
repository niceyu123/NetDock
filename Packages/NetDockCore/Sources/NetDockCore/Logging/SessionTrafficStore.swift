import Foundation

public struct TrafficSnapshot: Sendable {
    public let state: ConnectionState
    public let records: [TrafficRecord]
    public let peers: [PeerInfo]
    public let sentBytes: UInt64
    public let receivedBytes: UInt64
    public let sentPackets: UInt64
    public let receivedPackets: UInt64
    public let connectedDuration: TimeInterval
    public let lastError: NetDockError?
    public let listeningPort: UInt16?
    public let localEndpoint: String?
}

/// The network queue ingests into bounded memory; the UI requests changed snapshots.
public final class SessionTrafficStore: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: UUID
    private let mode: SessionMode
    private let protocolKind: TrafficRecord.ProtocolKind
    private var buffer: TrafficBuffer
    private var state: ConnectionState = .idle
    private var peers: [UUID: PeerInfo] = [:]
    private var sentBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var sentPackets: UInt64 = 0
    private var receivedPackets: UInt64 = 0
    private let clock = ContinuousClock()
    private var connectedSince: ContinuousClock.Instant?
    private var duration: TimeInterval = 0
    private var lastError: NetDockError?
    private var listeningPort: UInt16?
    private var localEndpoint: String?
    private var dirty = true
    private var lastSnapshotTime: ContinuousClock.Instant?

    public init(sessionID: UUID, mode: SessionMode = .tcpClient, maxEntries: Int = 5_000, maxBytes: Int = 30 * 1_024 * 1_024) {
        self.sessionID = sessionID; self.mode = mode; protocolKind = mode.isUDP ? .udp : .tcp
        buffer = TrafficBuffer(maxEntries: maxEntries, maxBytes: maxBytes)
    }

    public func ingest(_ event: NetworkEvent) {
        lock.lock(); defer { lock.unlock() }; dirty = true
        let now = clock.now
        switch event {
        case .stateChanged(let state):
            if mode == .tcpClient && state == .ready {
                if connectedSince == nil { connectedSince = now }
            } else if mode != .tcpServer || state != .listening {
                finishConnectedInterval(at: now)
            }
            self.state = state
            if state == .connecting || state == .starting { lastError = nil; listeningPort = nil; localEndpoint = nil }
            if !state.isActive { localEndpoint = nil; listeningPort = nil }
        case .system(let key):
            buffer.append(TrafficRecord(sessionID: sessionID, messageKey: key, protocolKind: protocolKind))
        case .listening(let port): listeningPort = port
        case .localEndpoint(let endpoint): localEndpoint = endpoint
        case .peerJoined(let info):
            if mode == .tcpServer, state == .listening, peers.isEmpty, connectedSince == nil {
                connectedSince = now
            }
            peers[info.id] = info
            buffer.append(TrafficRecord(sessionID: sessionID, remoteEndpoint: info.endpoint,
                localEndpoint: info.localEndpoint, messageKey: protocolKind == .udp ? "event.sourceAdded" : "event.peerJoined", protocolKind: protocolKind))
        case .peerLeft(let id):
            if let info = peers.removeValue(forKey: id) {
                if mode == .tcpServer && peers.isEmpty { finishConnectedInterval(at: now) }
                buffer.append(TrafficRecord(sessionID: sessionID, remoteEndpoint: info.endpoint,
                    localEndpoint: info.localEndpoint, messageKey: protocolKind == .udp ? "event.sourceRemoved" : "event.peerLeft", protocolKind: protocolKind))
            }
        case .received(let transfer):
            receivedBytes = Self.add(receivedBytes, transfer.payload.count); receivedPackets = Self.add(receivedPackets, 1)
            if let id = transfer.peerID, var peer = peers[id] {
                peer.bytesReceived = Self.add(peer.bytesReceived, transfer.payload.count); peers[id] = peer
            }
            append(transfer, direction: .rx)
        case .sendResult(let transfer, let error):
            if let error {
                lastError = error
                buffer.append(TrafficRecord(sessionID: sessionID, remoteEndpoint: transfer.remoteEndpoint, error: error, protocolKind: protocolKind))
            } else {
                sentBytes = Self.add(sentBytes, transfer.payload.count); sentPackets = Self.add(sentPackets, 1)
                if let id = transfer.peerID, var peer = peers[id] {
                    peer.bytesSent = Self.add(peer.bytesSent, transfer.payload.count); peers[id] = peer
                }
                append(transfer, direction: .tx)
            }
        case .error(let error):
            lastError = error; buffer.append(TrafficRecord(sessionID: sessionID, error: error, protocolKind: protocolKind))
        }
    }
    public func takeSnapshot() -> TrafficSnapshot? {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now
        guard dirty || (connectedSince != nil && (lastSnapshotTime.map { $0.duration(to: now) >= .seconds(1) } ?? true)) else { return nil }
        dirty = false; lastSnapshotTime = now
        return TrafficSnapshot(state: state, records: buffer.records,
            peers: peers.values.sorted { $0.connectedAt < $1.connectedAt },
            sentBytes: sentBytes, receivedBytes: receivedBytes, sentPackets: sentPackets, receivedPackets: receivedPackets,
            connectedDuration: duration + (connectedSince.map { seconds(from: $0, to: now) } ?? 0),
            lastError: lastError, listeningPort: listeningPort, localEndpoint: localEndpoint)
    }
    public func clear() { lock.lock(); buffer.removeAll(); dirty = true; lock.unlock() }
    /// Count the union of TCP peer lifetimes, using a monotonic clock.
    private func finishConnectedInterval(at now: ContinuousClock.Instant) {
        guard let since = connectedSince else { return }
        duration += seconds(from: since, to: now); connectedSince = nil
    }
    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = start.duration(to: end).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
    }
    private func append(_ transfer: Transfer, direction: TrafficRecord.Direction) {
        buffer.append(TrafficRecord(sessionID: sessionID, timestamp: transfer.timestamp, direction: direction,
            payload: transfer.payload, remoteEndpoint: transfer.remoteEndpoint, localEndpoint: transfer.localEndpoint, protocolKind: protocolKind))
    }
    private static func add(_ current: UInt64, _ bytes: Int) -> UInt64 {
        let result = current.addingReportingOverflow(UInt64(bytes)); return result.overflow ? .max : result.partialValue
    }
}
