#if os(macOS)
import Foundation

public enum MonitorChange: String, Codable, Sendable { case added, changed, disappeared, unchanged }
public struct MonitorRow: Identifiable, Hashable, Sendable {
    public let connection: MonitorConnection
    public var change: MonitorChange
    public let changedAt: Date
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public var id: MonitorConnectionIdentity { connection.id }
}

/// Bounded, in-memory history. A disappearance means "not observed", not proof of a TCP close.
public struct ConnectionMonitorDiff: Sendable {
    public static let highlightDuration: TimeInterval = 3
    public static let disappearanceDuration: TimeInterval = 5
    private var previous: [MonitorConnectionIdentity: MonitorRow] = [:]
    private let maximumRows: Int
    private var hasSystemSnapshot = false
    public init(maximumRows: Int = ConnectionMonitorCollector.maximumConnections) {
        self.maximumRows = min(ConnectionMonitorCollector.maximumConnections, max(1, maximumRows))
    }
    @discardableResult public mutating func apply(_ snapshot: MonitorSnapshot) -> Bool {
        // Preserve the whole last snapshot when one protocol failed or a non-atomic PCB read stayed inconsistent after retry.
        let coverage = snapshot.coverage
        guard (coverage.readableProcessCount > 0 || coverage.systemSnapshotReadable), coverage.issues[.cancelled] == nil else { return false }
        if !previous.isEmpty {
            if coverage.issues[.limitReached] != nil { return false }
            if coverage.systemSamplingAttempted && !coverage.systemSnapshotComplete && (coverage.systemSnapshotReadable || hasSystemSnapshot) { return false }
        }
        let now = snapshot.collectedAt
        var next: [MonitorConnectionIdentity: MonitorRow] = [:]
        for connection in snapshot.connections.prefix(maximumRows) {
            let old = previous[connection.id]
            let changed = old != nil && old?.connection != connection
            let appeared = old == nil || old?.change == .disappeared
            next[connection.id] = MonitorRow(connection: connection,
                                             change: appeared ? .added : (changed ? .changed : old!.change),
                                             changedAt: appeared || changed ? now : old!.changedAt,
                                             firstSeenAt: old?.firstSeenAt ?? now, lastSeenAt: now)
        }
        // Prioritize live rows, then the most recently seen missing rows, always under the same cap.
        let missing = previous.values.filter { next[$0.id] == nil }.sorted {
            $0.lastSeenAt == $1.lastSeenAt ? monitorIdentityLess($0.id, $1.id) : $0.lastSeenAt > $1.lastSeenAt
        }
        for old in missing where next.count < maximumRows {
            let disappearedAt = old.change == .disappeared ? old.changedAt : now
            guard now.timeIntervalSince(disappearedAt) < Self.disappearanceDuration else { continue }
            next[old.id] = MonitorRow(connection: old.connection, change: .disappeared, changedAt: disappearedAt,
                                      firstSeenAt: old.firstSeenAt, lastSeenAt: old.lastSeenAt)
        }
        previous = next
        hasSystemSnapshot = hasSystemSnapshot || coverage.systemSnapshotReadable
        return true
    }
    /// Computes expiry from wall time, so paused monitoring never leaves disappearance highlights on screen forever.
    public func rows(at date: Date) -> [MonitorRow] {
        previous.values.compactMap { original in
            var row = original
            let age = date.timeIntervalSince(row.changedAt)
            if row.change == .disappeared { return age < Self.disappearanceDuration ? row : nil }
            if age >= Self.highlightDuration { row.change = .unchanged }
            return row
        }
    }
}

public struct MonitorFilter: Sendable {
    public var search: String
    public var transport: MonitorTransport?
    public var localPort: UInt16?
    public init(search: String = "", transport: MonitorTransport? = nil, localPort: UInt16? = nil) {
        self.search = search; self.transport = transport; self.localPort = localPort
    }
}
public enum MonitorSortField: String, CaseIterable, Sendable {
    case processName, pid, transport, localAddress, localPort, remoteAddress, remotePort, tcpState, change
}
public struct MonitorRowComparator: SortComparator, Sendable {
    public let field: MonitorSortField
    public var order: SortOrder
    public init(_ field: MonitorSortField, order: SortOrder = .forward) { self.field = field; self.order = order }
    public func compare(_ lhs: MonitorRow, _ rhs: MonitorRow) -> ComparisonResult {
        let a = lhs.connection; let b = rhs.connection
        let result: ComparisonResult
        switch field {
        case .processName: result = (a.processName ?? "\u{10ffff}").localizedStandardCompare(b.processName ?? "\u{10ffff}")
        case .pid: result = monitorCompare(a.id.process?.pid ?? Int32.max, b.id.process?.pid ?? Int32.max)
        case .transport: result = a.transport.rawValue.compare(b.transport.rawValue)
        case .localAddress: result = a.local.address.localizedStandardCompare(b.local.address)
        case .localPort: result = monitorCompare(a.local.port, b.local.port)
        case .remoteAddress: result = a.remote.address.localizedStandardCompare(b.remote.address)
        case .remotePort: result = monitorCompare(a.remote.port, b.remote.port)
        case .tcpState: result = a.stateName.compare(b.stateName)
        case .change: result = lhs.change.rawValue.compare(rhs.change.rawValue)
        }
        guard order == .reverse else { return result }
        switch result { case .orderedAscending: return .orderedDescending; case .orderedDescending: return .orderedAscending; case .orderedSame: return .orderedSame }
    }
}
public enum MonitorQuery {
    public static func rows(_ rows: [MonitorRow], filter: MonitorFilter, sort: [MonitorRowComparator]) -> [MonitorRow] {
        let terms = filter.search.split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { row in
            let item = row.connection
            if let transport = filter.transport, item.transport != transport { return false }
            if let port = filter.localPort, item.local.port != port { return false }
            if terms.isEmpty { return true }
            let text = [item.processName ?? "", item.id.process.map { String($0.pid) } ?? "", item.transport.rawValue, item.family.rawValue,
                        item.local.formatted, item.remote.formatted, item.stateName].joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted { a, b in
            for comparator in sort {
                let result = comparator.compare(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return monitorIdentityLess(a.id, b.id)
        }
    }
}
private func monitorCompare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
}
private func monitorIdentityLess(_ a: MonitorConnectionIdentity, _ b: MonitorConnectionIdentity) -> Bool {
    if (a.process == nil) != (b.process == nil) { return a.process != nil }
    if let ap = a.process, let bp = b.process {
        if ap.pid != bp.pid { return ap.pid < bp.pid }
        if ap.startSeconds != bp.startSeconds { return ap.startSeconds < bp.startSeconds }
        if ap.startMicroseconds != bp.startMicroseconds { return ap.startMicroseconds < bp.startMicroseconds }
    }
    if a.fileDescriptor != b.fileDescriptor { return (a.fileDescriptor ?? -1) < (b.fileDescriptor ?? -1) }
    if a.transport != b.transport { return a.transport.rawValue < b.transport.rawValue }
    if a.family != b.family { return a.family.rawValue < b.family.rawValue }
    if a.socketIdentifier != b.socketIdentifier { return a.socketIdentifier < b.socketIdentifier }
    return a.generation < b.generation
}
#endif
