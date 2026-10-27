#if os(macOS)
import Foundation

public enum MonitorTransport: String, Codable, CaseIterable, Sendable { case tcp = "TCP", udp = "UDP" }
public enum MonitorIPFamily: String, Codable, Sendable { case ipv4 = "IPv4", ipv6 = "IPv6" }
/// Successful snapshots are partial: protected attribution and short-lived sockets may remain invisible.
public enum MonitorScope: String, Codable, Sendable { case ownProcessOnly, partialSystem, unavailable }
public enum MonitorTCPState: Int32, Codable, Sendable {
    case unknown = -1, closed = 0, listen = 1, synSent = 2, synReceived = 3, established = 4
    case closeWait = 5, finWait1 = 6, closing = 7, lastAck = 8, finWait2 = 9, timeWait = 10, reserved = 11
    public var name: String {
        switch self {
        case .unknown: "UNKNOWN"
        case .closed: "CLOSED"
        case .listen: "LISTEN"
        case .synSent: "SYN_SENT"
        case .synReceived: "SYN_RECEIVED"
        case .established: "ESTABLISHED"
        case .closeWait: "CLOSE_WAIT"
        case .finWait1: "FIN_WAIT_1"
        case .closing: "CLOSING"
        case .lastAck: "LAST_ACK"
        case .finWait2: "FIN_WAIT_2"
        case .timeWait: "TIME_WAIT"
        case .reserved: "RESERVED"
        }
    }
}
public struct MonitorProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
    public var startedAt: Date { Date(timeIntervalSince1970: Double(startSeconds) + Double(startMicroseconds) / 1_000_000) }
}
public struct MonitorConnectionIdentity: Hashable, Codable, Sendable {
    public let process: MonitorProcessIdentity?
    public let fileDescriptor: Int32?
    /// Opaque libproc / PCB handles are used only in bounded memory to distinguish socket and FD reuse.
    public let socketIdentifier: UInt64
    public let generation: UInt64
    public let transport: MonitorTransport
    public let family: MonitorIPFamily
    public init(process: MonitorProcessIdentity?, fileDescriptor: Int32?, socketIdentifier: UInt64, generation: UInt64, transport: MonitorTransport = .tcp, family: MonitorIPFamily = .ipv4) {
        self.process = process; self.fileDescriptor = fileDescriptor
        self.socketIdentifier = socketIdentifier; self.generation = generation; self.transport = transport; self.family = family
    }
}
public struct MonitorEndpoint: Hashable, Codable, Sendable {
    public let address: String
    public let port: UInt16
    public init(address: String, port: UInt16) { self.address = address; self.port = port }
    public var formatted: String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
}
public struct MonitorConnection: Identifiable, Hashable, Codable, Sendable {
    public let id: MonitorConnectionIdentity
    public let processName: String?
    public let transport: MonitorTransport
    public let family: MonitorIPFamily
    public let local: MonitorEndpoint
    public let remote: MonitorEndpoint
    public let tcpState: MonitorTCPState?
    public init(id: MonitorConnectionIdentity, processName: String?, transport: MonitorTransport, family: MonitorIPFamily,
                local: MonitorEndpoint, remote: MonitorEndpoint, tcpState: MonitorTCPState?) {
        self.id = id; self.processName = processName; self.transport = transport; self.family = family
        self.local = local; self.remote = remote; self.tcpState = tcpState
    }
    public var stateName: String { tcpState?.name ?? "—" }
}
public enum MonitorIssue: String, Codable, CaseIterable, Sendable {
    case permissionDenied, processEnded, unavailable, limitReached, inconsistentRead, cancelled
}
public struct MonitorCoverage: Hashable, Codable, Sendable {
    public var enumeratedProcessCount: Int
    public var readableProcessCount: Int
    public var readableOtherProcessCount: Int
    public var systemSamplingAttempted: Bool
    public var systemSnapshotReadable: Bool
    public var systemSnapshotComplete: Bool
    public var systemSocketCount: Int
    public var unattributedConnectionCount: Int
    public var issues: [MonitorIssue: Int]
    public init(enumeratedProcessCount: Int = 0, readableProcessCount: Int = 0,
                readableOtherProcessCount: Int = 0, systemSamplingAttempted: Bool = false, systemSnapshotReadable: Bool = false,
                systemSnapshotComplete: Bool = false, systemSocketCount: Int = 0,
                unattributedConnectionCount: Int = 0, issues: [MonitorIssue: Int] = [:]) {
        self.enumeratedProcessCount = enumeratedProcessCount; self.readableProcessCount = readableProcessCount
        self.readableOtherProcessCount = readableOtherProcessCount; self.systemSamplingAttempted = systemSamplingAttempted
        self.systemSnapshotReadable = systemSnapshotReadable; self.systemSnapshotComplete = systemSnapshotComplete
        self.systemSocketCount = systemSocketCount; self.unattributedConnectionCount = unattributedConnectionCount; self.issues = issues
    }
    public var scope: MonitorScope {
        (systemSnapshotReadable || readableOtherProcessCount > 0) ? .partialSystem : (readableProcessCount > 0 ? .ownProcessOnly : .unavailable)
    }
}
public struct MonitorSnapshot: Sendable {
    public let collectedAt: Date
    public let connections: [MonitorConnection]
    public let coverage: MonitorCoverage
    public init(collectedAt: Date, connections: [MonitorConnection], coverage: MonitorCoverage) {
        self.collectedAt = collectedAt; self.connections = connections; self.coverage = coverage
    }
}
#endif
