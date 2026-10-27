import Foundation

public enum PayloadCodec {
    public static func encode(_ text: String, as encoding: DataEncoding) throws -> Data {
        if encoding == .utf8 {
            guard !text.isEmpty else { throw NetDockError(.emptyPayload) }
            return Data(text.utf8)
        }
        var data = Data(capacity: min(text.utf8.count / 2, 64 * 1_024))
        var highNibble: UInt8?
        var lastPosition = 0
        for (offset, character) in text.enumerated() {
            if character.isWhitespace { continue }
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
                throw NetDockError(.invalidHex, position: offset + 1)
            }
            let value: UInt8
            switch scalar.value {
            case 48...57: value = UInt8(scalar.value - 48)
            case 65...70: value = UInt8(scalar.value - 55)
            case 97...102: value = UInt8(scalar.value - 87)
            default: throw NetDockError(.invalidHex, position: offset + 1)
            }
            lastPosition = offset + 1
            if let high = highNibble { data.append(high * 16 + value); highNibble = nil }
            else { highNibble = value }
        }
        guard highNibble == nil else { throw NetDockError(.oddHex, position: lastPosition) }
        guard !data.isEmpty else { throw NetDockError(.emptyPayload) }
        return data
    }

    public static func text(_ data: Data) -> String? { String(data: data, encoding: .utf8) }
    public static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
