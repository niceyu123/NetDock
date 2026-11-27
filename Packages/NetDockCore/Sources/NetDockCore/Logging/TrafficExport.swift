import Foundation

public enum TrafficExport {
    public static func json(_ records: [TrafficRecord]) throws -> Data {
        let formatter = timestampFormatter()
        let document = Document(records: records.map { record in
            Entry(id: record.id, sessionID: record.sessionID, timestamp: timestamp(record.timestamp, formatter: formatter),
                  direction: record.direction.rawValue, protocolName: record.protocolKind.rawValue,
                  localEndpoint: record.localEndpoint, remoteEndpoint: record.remoteEndpoint,
                  size: record.size, payload: record.payload, kind: kind(record), messageKey: record.messageKey,
                  error: record.error.map { ErrorEntry(code: $0.code.rawValue, detail: $0.detail, position: $0.position) })
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public static func text(_ records: [TrafficRecord]) -> String {
        let formatter = timestampFormatter()
        return records.map { record in
            var fields = ["\(timestamp(record.timestamp, formatter: formatter)) \(record.protocolKind.rawValue) \(record.direction.rawValue)",
                          "local=\(record.localEndpoint ?? "-") remote=\(record.remoteEndpoint ?? "-") size=\(record.size)"]
            if record.direction != .system || !record.payload.isEmpty {
                fields.append("HEX: \(PayloadCodec.hex(record.payload))")
                if let text = PayloadCodec.text(record.payload) { fields.append("UTF-8: \(String(reflecting: text))") }
                else { fields.append("UTF-8: <invalid UTF-8>") }
            }
            if let key = record.messageKey { fields.append("system: \(key)") }
            if let error = record.error {
                fields.append("error: \(error.code.rawValue)\(error.detail.isEmpty ? "" : " \(error.detail)")\(error.position.map { " position=\($0)" } ?? "")")
            }
            return fields.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private static func kind(_ record: TrafficRecord) -> String {
        switch record.kind { case .data: "data"; case .system: "system"; case .error: "error" }
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// Preserve microseconds rather than ISO8601DateFormatter's millisecond-only fraction.
    private static func timestamp(_ date: Date, formatter: ISO8601DateFormatter) -> String {
        let time = date.timeIntervalSince1970
        guard time.isFinite else { return "invalid-timestamp" }
        var seconds = floor(time)
        var micros = Int(((time - seconds) * 1_000_000).rounded())
        if micros == 1_000_000 { seconds += 1; micros = 0 }
        let whole = formatter.string(from: Date(timeIntervalSince1970: seconds))
        return "\(whole.dropLast())\(String(format: ".%06dZ", micros))"
    }

    private struct Document: Encodable { let schemaVersion = 1; let records: [Entry] }
    private struct Entry: Encodable {
        let id: UUID
        let sessionID: UUID
        let timestamp: String
        let direction: String
        let protocolName: String
        let localEndpoint: String?
        let remoteEndpoint: String?
        let size: Int
        let payload: Data
        let kind: String
        let messageKey: String?
        let error: ErrorEntry?
        private enum CodingKeys: String, CodingKey {
            case id, sessionID, timestamp, direction, protocolName = "protocol", localEndpoint, remoteEndpoint
            case size, payload, kind, messageKey, error
        }
    }
    private struct ErrorEntry: Encodable { let code: String; let detail: String; let position: Int? }
}

public struct TrafficQuery: Sendable {
    public var search: String {
        didSet {
            query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            hexPattern = HexPattern(query)
        }
    }
    public var direction: TrafficRecord.Direction?
    private var query: String
    private var hexPattern: HexPattern?

    public init(search: String = "", direction: TrafficRecord.Direction? = nil) {
        self.search = search; self.direction = direction
        query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        hexPattern = HexPattern(query)
    }

    public func matches(_ record: TrafficRecord) -> Bool {
        guard direction == nil || record.direction == direction else { return false }
        guard !query.isEmpty else { return true }
        var fields = [record.direction.rawValue, record.protocolKind.rawValue]
        fields += [record.localEndpoint, record.remoteEndpoint, record.messageKey].compactMap { $0 }
        if record.direction == .system { fields.append("system") }
        if let error = record.error { fields += ["error", error.code.rawValue, error.detail] }
        func contains(_ text: String) -> Bool { text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if fields.contains(where: contains) { return true }
        if let text = PayloadCodec.text(record.payload), contains(text) { return true }
        return hexPattern?.matches(record.payload) ?? false
    }

    /// Search the byte stream's nibbles directly, including partial-byte queries.
    /// KMP keeps overlapping patterns linear without formatting or copying the payload.
    private struct HexPattern: Sendable {
        let nibbles: [UInt8]
        let fallback: [Int]

        init?(_ query: String) {
            var nibbles: [UInt8] = []
            for scalar in query.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                switch scalar.value {
                case 48...57: nibbles.append(UInt8(scalar.value - 48))
                case 65...70: nibbles.append(UInt8(scalar.value - 55))
                case 97...102: nibbles.append(UInt8(scalar.value - 87))
                default: return nil
                }
            }
            guard !nibbles.isEmpty else { return nil }
            var fallback = [Int](repeating: 0, count: nibbles.count)
            var matched = 0
            for index in nibbles.indices.dropFirst() {
                while matched > 0 && nibbles[index] != nibbles[matched] { matched = fallback[matched - 1] }
                if nibbles[index] == nibbles[matched] { matched += 1 }
                fallback[index] = matched
            }
            self.nibbles = nibbles; self.fallback = fallback
        }

        func matches(_ data: Data) -> Bool {
            guard nibbles.count <= data.count * 2 else { return false }
            return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var matched = 0
                func consume(_ nibble: UInt8) -> Bool {
                    while matched > 0 && nibble != nibbles[matched] { matched = fallback[matched - 1] }
                    if nibble == nibbles[matched] { matched += 1 }
                    return matched == nibbles.count
                }
                for byte in bytes {
                    if consume(byte >> 4) || consume(byte & 0x0F) { return true }
                }
                return false
            }
        }
    }
}
