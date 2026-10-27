import Foundation

public struct PeerInfo: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let endpoint: String
    public let localEndpoint: String?
    public let connectedAt: Date
    public var state: ConnectionState = .ready
    public var bytesSent: UInt64 = 0
    public var bytesReceived: UInt64 = 0
}

public enum SendTarget: Equatable, Sendable {
    case remote, peer(UUID), allPeers
    case endpoint(host: String, port: UInt16)
}

public struct Transfer: Sendable {
    public let timestamp: Date
    public let payload: Data
    public let peerID: UUID?
    public let remoteEndpoint: String
    public let localEndpoint: String?
}

public struct SendOutcome: Sendable {
    public let peerID: UUID?
    public let endpoint: String
    public let error: NetDockError?
}

public enum NetworkEvent: Sendable {
    case stateChanged(ConnectionState)
    case system(String)
    case listening(port: UInt16)
    case localEndpoint(String)
    case peerJoined(PeerInfo)
    case peerLeft(UUID)
    case received(Transfer)
    case sendResult(Transfer, NetDockError?)
    case error(NetDockError)
}

/// The sink runs on the transport's serial queue. It must be fast and thread-safe.
/// This avoids an unbounded AsyncStream retaining raw network payloads under load.
public protocol TransportService: Sendable {
    func start(_ config: SessionConfig) async throws
    func stop() async
    func send(_ data: Data, to target: SendTarget) async throws -> [SendOutcome]
    func disconnect(peerID: UUID) async
}
