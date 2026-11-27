import Foundation
import Network

public enum DNSRecordType: UInt16, CaseIterable, Sendable {
    case a = 1, ns = 2, cname = 5, soa = 6, ptr = 12, mx = 15, txt = 16, aaaa = 28
    public var title: String { String(describing: self).uppercased() }
}

public struct DNSQuery: Sendable {
    public let name: String
    public let type: DNSRecordType
    public let server: String
    public let port: UInt16
    public var resolverEndpoint: String { "\(server.contains(":") ? "[\(server)]" : server):\(port)" }

    public init(name: String, type: DNSRecordType = .a, server: String = "1.1.1.1", port: UInt16 = 53) throws {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type == .ptr, let address = IPv4Address(name) {
            name = address.rawValue.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa"
        } else if type == .ptr, !name.contains("%"), let address = IPv6Address(name) {
            name = address.rawValue.flatMap { [String($0 >> 4, radix: 16), String($0 & 15, radix: 16)] }.reversed().joined(separator: ".") + ".ip6.arpa"
        }
        if name.hasSuffix("."), name != "." { name.removeLast() }
        guard name == "." || (!name.isEmpty && name.utf8.count <= 253 && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
        }), port > 0 else { throw NetDockError(.invalidDNSQuery) }
        self.server = try EndpointInput.unicastHost(server)
        self.name = name; self.type = type; self.port = port
    }
}

public struct DNSRecord: Identifiable, Sendable {
    public enum Section: String, CaseIterable, Sendable { case answer, authority, additional }
    public let id = UUID()
    public let name: String
    public let type: UInt16
    public let recordClass: UInt16
    public let ttl: UInt32
    public let value: String
    public let section: Section
    public var typeTitle: String { DNSRecordType(rawValue: type)?.title ?? "TYPE\(type)" }
}

public struct DNSMessage: Sendable {
    public let responseCode: UInt16
    public let authoritative: Bool
    public let truncated: Bool
    public let recursionAvailable: Bool
    public let records: [DNSRecord]
    public let rawData: Data
    public var status: String {
        switch responseCode { case 0: "NOERROR"; case 1: "FORMERR"; case 2: "SERVFAIL"; case 3: "NXDOMAIN"; case 4: "NOTIMP"; case 5: "REFUSED"; default: "RCODE\(responseCode)" }
    }
}

/// Bounded RFC 1035 wire encoder/decoder. No DNSSEC validation is implied.
enum DNSWire {
    static func encode(_ query: DNSQuery, id: UInt16) -> Data {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        if query.name != "." {
            for label in query.name.split(separator: ".") { bytes.append(UInt8(label.utf8.count)); bytes.append(contentsOf: label.utf8) }
        }
        bytes += [0, UInt8(query.type.rawValue >> 8), UInt8(query.type.rawValue & 255), 0, 1]
        return Data(bytes)
    }

    static func decode(_ data: Data, query: DNSQuery, id: UInt16) throws -> DNSMessage {
        let bytes = Array(data)
        guard bytes.count >= 12, bytes.count <= 65_535 else { throw NetDockError(.dnsMalformed) }
        var reader = Reader(bytes: bytes)
        guard try reader.u16() == id else { throw NetDockError(.dnsMismatch) }
        let flags = try reader.u16()
        guard flags & 0x8000 != 0, flags & 0x7800 == 0, try reader.u16() == 1 else { throw NetDockError(.dnsMismatch) }
        let counts = try [reader.u16(), reader.u16(), reader.u16()]
        guard counts.reduce(0, { $0 + Int($1) }) <= 2048 else { throw NetDockError(.dnsMalformed) }
        let name = try reader.name()
        guard name.lowercased() == query.name, try reader.u16() == query.type.rawValue, try reader.u16() == 1 else { throw NetDockError(.dnsMismatch) }
        var records: [DNSRecord] = []
        if flags & 0x0200 == 0 {
            for (section, count) in zip(DNSRecord.Section.allCases, counts) {
                for _ in 0..<count {
                    let owner = try reader.name(), type = try reader.u16(), recordClass = try reader.u16()
                    let ttl = try reader.u32(), length = Int(try reader.u16())
                    let end = reader.cursor + length
                    guard end <= bytes.count else { throw NetDockError(.dnsMalformed) }
                    let value = try reader.value(type: recordClass == 1 ? type : 0, end: end)
                    guard reader.cursor == end else { throw NetDockError(.dnsMalformed) }
                    records.append(DNSRecord(name: owner, type: type, recordClass: recordClass, ttl: ttl, value: value, section: section))
                }
            }
            guard reader.cursor == bytes.count else { throw NetDockError(.dnsMalformed) }
        }
        return DNSMessage(responseCode: flags & 15, authoritative: flags & 0x0400 != 0, truncated: flags & 0x0200 != 0,
                          recursionAvailable: flags & 0x0080 != 0, records: records, rawData: data)
    }

    private struct Reader {
        let bytes: [UInt8]
        var cursor = 0
        mutating func u16() throws -> UInt16 {
            guard cursor + 2 <= bytes.count else { throw NetDockError(.dnsMalformed) }
            defer { cursor += 2 }; return UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
        }
        mutating func u32() throws -> UInt32 { let high = try u16(); return UInt32(high) << 16 | UInt32(try u16()) }
        mutating func name() throws -> String {
            var position = cursor, next: Int?, labels: [String] = [], visited = Set<Int>(), length = 1
            while true {
                guard position < bytes.count, visited.count < 128, visited.insert(position).inserted else { throw NetDockError(.dnsMalformed) }
                let size = Int(bytes[position])
                if size & 0xC0 == 0xC0 {
                    guard position + 1 < bytes.count else { throw NetDockError(.dnsMalformed) }
                    let offset = (size & 63) << 8 | Int(bytes[position + 1])
                    guard offset >= 12, offset < position else { throw NetDockError(.dnsMalformed) }
                    if next == nil { next = position + 2 }
                    position = offset; continue
                }
                guard size <= 63, position + size + 1 <= bytes.count else { throw NetDockError(.dnsMalformed) }
                position += 1
                if size == 0 { cursor = next ?? position; return labels.isEmpty ? "." : labels.joined(separator: ".") }
                length += size + 1
                guard length <= 255 else { throw NetDockError(.dnsMalformed) }
                labels.append(Self.escaped(bytes[position..<(position + size)]))
                position += size
            }
        }
        private static func escaped(_ data: ArraySlice<UInt8>) -> String {
            data.map { byte in
                (33...126).contains(byte) && byte != 46 && byte != 92 ? String(UnicodeScalar(byte)) : String(format: "\\%03d", byte)
            }.joined()
        }
        mutating func value(type: UInt16, end: Int) throws -> String {
            let start = cursor
            switch DNSRecordType(rawValue: type) {
            case .a:
                guard end - start == 4, let ip = IPv4Address(Data(bytes[start..<end])) else { throw NetDockError(.dnsMalformed) }
                cursor = end; return ip.debugDescription
            case .aaaa:
                guard end - start == 16, let ip = IPv6Address(Data(bytes[start..<end])) else { throw NetDockError(.dnsMalformed) }
                cursor = end; return ip.debugDescription
            case .cname, .ns, .ptr: return try name()
            case .mx:
                let preference = try u16(); return "\(preference) \(try name())"
            case .soa:
                let primary = try name(), mailbox = try name()
                let numbers = try (0..<5).map { _ in try u32() }
                return ([primary, mailbox] + numbers.map(String.init)).joined(separator: " ")
            case .txt:
                var texts: [String] = []
                while cursor < end {
                    let size = Int(bytes[cursor]); cursor += 1
                    guard cursor + size <= end else { throw NetDockError(.dnsMalformed) }
                    let part = bytes[cursor..<(cursor + size)]
                    // Preserve arbitrary bytes through escapes; never insert control characters into the UI.
                    texts.append("\"" + part.map { byte in
                        if byte == 34 || byte == 92 { return "\\" + String(UnicodeScalar(byte)) }
                        return (32...126).contains(byte) ? String(UnicodeScalar(byte)) : String(format: "\\%03d", byte)
                    }.joined() + "\"")
                    cursor += size
                }
                return texts.joined(separator: " ")
            case nil:
                cursor = end; return PayloadCodec.hex(Data(bytes[start..<end]))
            }
        }
    }
}
