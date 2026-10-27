#if os(macOS)
import Foundation
import Darwin

enum MonitorAddressDecoder {
    static func ipv4(_ original: in_addr) -> String? {
        var address = original
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static func ipv6(_ original: in6_addr, interfaceIndex: UInt16) -> String? {
        var address = original
        var scope: UInt32 = 0
        withUnsafeMutableBytes(of: &address) { bytes in
            // Darwin may embed an interface index in link-local addresses (KAME representation).
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 {
                scope = UInt32(bytes[2]) << 8 | UInt32(bytes[3])
                bytes[2] = 0; bytes[3] = 0
                if scope == 0 { scope = UInt32(interfaceIndex) }
            }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + (scope > 0 ? "%\(scope)" : "")
    }
}
#endif
