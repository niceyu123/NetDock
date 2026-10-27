#if os(macOS)
import Foundation

public enum MonitorExportFormat: String, CaseIterable, Sendable { case csv, json }
/// Explicit exports contain only the caller's visible rows. No snapshot is persisted automatically.
public enum ConnectionMonitorExport {
    public static func data(snapshot: MonitorSnapshot, rows: [MonitorRow], format: MonitorExportFormat) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let captured = formatter.string(from: snapshot.collectedAt)
        switch format {
        case .json:
            let records: [[String: Any]] = rows.map { row in
                let item = row.connection
                return ["process": item.processName.map { $0 as Any } ?? NSNull(), "pid": item.id.process.map { Int($0.pid) as Any } ?? NSNull(),
                        "attribution": item.id.process == nil ? "unavailable" : "libproc", "protocol": item.transport.rawValue,
                        "family": item.family.rawValue, "localAddress": item.local.address, "localPort": Int(item.local.port),
                        "remoteAddress": item.remote.address, "remotePort": Int(item.remote.port),
                        "tcpState": item.tcpState.map { $0.name as Any } ?? NSNull(), "change": row.change.rawValue,
                        "firstSeen": formatter.string(from: row.firstSeenAt), "lastSeen": formatter.string(from: row.lastSeenAt)]
            }
            let coverage = snapshot.coverage
            let issues = Dictionary(uniqueKeysWithValues: coverage.issues.map { ($0.key.rawValue, $0.value) })
            return try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "capturedAt": captured, "scope": coverage.scope.rawValue,
                "limitations": ["partialVisibility", "processAttributionMayBeUnavailable", "noTIME_WAITGuarantee", "disappearanceIsNotProofOfClose"],
                "coverage": ["enumeratedProcesses": coverage.enumeratedProcessCount, "readableProcesses": coverage.readableProcessCount,
                             "readableOtherProcesses": coverage.readableOtherProcessCount, "systemSnapshotReadable": coverage.systemSnapshotReadable, "systemSnapshotComplete": coverage.systemSnapshotComplete,
                             "systemSockets": coverage.systemSocketCount, "unattributedConnections": coverage.unattributedConnectionCount, "issues": issues],
                "connections": records
            ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        case .csv:
            let headers = ["captured_at", "scope", "process", "pid", "attribution", "protocol", "family", "local_address", "local_port",
                           "remote_address", "remote_port", "tcp_state", "change", "first_seen", "last_seen"]
            let lines = rows.map { row in
                let item = row.connection
                return [captured, snapshot.coverage.scope.rawValue, item.processName ?? "", item.id.process.map { String($0.pid) } ?? "", item.id.process == nil ? "unavailable" : "libproc",
                        item.transport.rawValue, item.family.rawValue, item.local.address, String(item.local.port),
                        item.remote.address, String(item.remote.port), item.tcpState?.name ?? "", row.change.rawValue,
                        formatter.string(from: row.firstSeenAt), formatter.string(from: row.lastSeenAt)]
                    .map(csvCell).joined(separator: ",")
            }
            return Data(([headers.joined(separator: ",")] + lines).joined(separator: "\r\n").appending("\r\n").utf8)
        }
    }
    private static func csvCell(_ original: String) -> String {
        // Process names are untrusted. Neutralize formulas before RFC 4180 quoting, including leading whitespace.
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let dangerous = trimmed.first.map { "=+-@".contains($0) } == true || original.first.map { "\t\r\n".contains($0) } == true
        let text = dangerous ? "'" + original : original
        return text.contains(where: { ",\"\r\n".contains($0) }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
}
#endif
