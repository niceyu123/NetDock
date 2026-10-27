import Foundation

public struct TrafficRecord: Identifiable, Sendable {
    public enum Direction: String, Sendable { case tx = "TX", rx = "RX", system = "SYS" }
    public enum Kind: Equatable, Sendable { case data, system, error }
    public enum ProtocolKind: String, Sendable { case tcp = "TCP", udp = "UDP" }
    public let id: UUID
    public let sessionID: UUID
    public let timestamp: Date
    public let direction: Direction
    public let protocolKind: ProtocolKind
    public let payload: Data
    public let remoteEndpoint: String?
    public let localEndpoint: String?
    public let messageKey: String?
    public let error: NetDockError?
    public var size: Int { payload.count }
    public var kind: Kind { error != nil ? .error : direction == .system ? .system : .data }

    public init(sessionID: UUID, timestamp: Date = .now, direction: Direction = .system,
                payload: Data = Data(), remoteEndpoint: String? = nil, localEndpoint: String? = nil,
                messageKey: String? = nil, error: NetDockError? = nil, protocolKind: ProtocolKind = .tcp) {
        id = UUID(); self.sessionID = sessionID; self.timestamp = timestamp; self.direction = direction
        self.payload = payload; self.remoteEndpoint = remoteEndpoint; self.localEndpoint = localEndpoint
        self.messageKey = messageKey; self.error = error
        self.protocolKind = protocolKind
    }
}

/// Fixed-capacity ring: insertion and eviction do not shift retained payloads.
public struct TrafficBuffer: Sendable {
    private var slots: [TrafficRecord?]
    private var head = 0
    public private(set) var count = 0
    public private(set) var payloadBytes = 0
    public let maxBytes: Int
    public var maxEntries: Int { slots.count }

    public init(maxEntries: Int = 5_000, maxBytes: Int = 30 * 1_024 * 1_024) {
        slots = Array(repeating: nil, count: max(1, maxEntries)); self.maxBytes = max(0, maxBytes)
    }
    public mutating func append(_ record: TrafficRecord) {
        guard record.size <= maxBytes else { return }
        while count > 0 && (count == maxEntries || payloadBytes > maxBytes - record.size) { removeFirst() }
        slots[(head + count) % maxEntries] = record
        count += 1; payloadBytes += record.size
    }
    private mutating func removeFirst() {
        payloadBytes -= slots[head]?.size ?? 0; slots[head] = nil
        head = (head + 1) % maxEntries; count -= 1
    }
    public mutating func removeAll() {
        slots = Array(repeating: nil, count: maxEntries); head = 0; count = 0; payloadBytes = 0
    }
    public var records: [TrafficRecord] { (0..<count).compactMap { slots[(head + $0) % maxEntries] } }
}
