#if os(macOS)
import Foundation
import Darwin

struct SystemSocketSnapshot: Sendable {
    let readable: Bool
    let consistent: Bool
    let connections: [MonitorConnection]
    let issues: [MonitorIssue: Int]
}

/// Uses only SDK-declared pcblist64 / xtcpcb64 / xinpcb64. No private pcblist_n ABI or byte offsets.
enum SystemSocketSnapshotReader {
    private static let maximumBytes = 16 * 1024 * 1024
    static func read(_ transport: MonitorTransport) -> SystemSocketSnapshot {
        let name = transport == .tcp ? "net.inet.tcp.pcblist64" : "net.inet.udp.pcblist64"
        for attempt in 0..<2 {
            var needed = 0
            errno = 0
            guard sysctlbyname(name, nil, &needed, nil, 0) == 0 else { return failed(errno) }
            guard needed >= MemoryLayout<xinpgen>.size * 2, needed <= maximumBytes else {
                return SystemSocketSnapshot(readable: false, consistent: false, connections: [], issues: [.limitReached: 1])
            }
            // The kernel's size estimate includes spare space, but sockets can grow between size and read calls.
            var data = Data(count: min(maximumBytes, needed + 32_768))
            var size = data.count
            errno = 0
            let status = data.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
            if status != 0 {
                if errno == ENOMEM && attempt == 0 { continue }
                return failed(errno)
            }
            guard size <= data.count else { return SystemSocketSnapshot(readable: false, consistent: false, connections: [], issues: [.limitReached: 1]) }
            data.count = size
            let result = parse(data, transport: transport)
            if result.readable && !result.consistent && attempt == 0 { continue }
            return result
        }
        return SystemSocketSnapshot(readable: false, consistent: false, connections: [], issues: [.unavailable: 1])
    }

    static func parse(_ data: Data, transport: MonitorTransport) -> SystemSocketSnapshot {
        let markerSize = MemoryLayout<xinpgen>.size
        let recordSize = transport == .tcp ? MemoryLayout<xtcpcb64>.size : MemoryLayout<xinpcb64>.size
        guard data.count >= markerSize * 2 else { return invalid() }
        return data.withUnsafeBytes { bytes in
            let head = bytes.loadUnaligned(as: xinpgen.self)
            guard Int(head.xig_len) == markerSize else { return invalid() }
            var offset = markerSize
            var connections: [MonitorConnection] = []
            var tail: xinpgen?
            var issues: [MonitorIssue: Int] = [:]
            while offset + markerSize <= bytes.count {
                let size = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                if size == markerSize {
                    guard offset + markerSize == bytes.count else { return invalid() }
                    tail = bytes.loadUnaligned(fromByteOffset: offset, as: xinpgen.self)
                    break
                }
                guard size == recordSize, offset + size <= bytes.count else { return invalid() }
                let pcb: xinpcb64
                let state: MonitorTCPState?
                if transport == .tcp {
                    let tcp = bytes.loadUnaligned(fromByteOffset: offset, as: xtcpcb64.self)
                    pcb = tcp.xt_inpcb
                    state = MonitorTCPState(rawValue: tcp.t_state) ?? .unknown
                } else {
                    pcb = bytes.loadUnaligned(fromByteOffset: offset, as: xinpcb64.self); state = nil
                }
                if let item = decode(pcb, transport: transport, state: state) {
                    if connections.count < ConnectionMonitorCollector.maximumConnections { connections.append(item) }
                    else { issues[.limitReached] = 1 }
                }
                offset += size
            }
            guard let tail else { return invalid() }
            let consistent = head.xig_gen == tail.xig_gen && head.xig_sogen == tail.xig_sogen && issues[.limitReached] == nil
            if head.xig_gen != tail.xig_gen || head.xig_sogen != tail.xig_sogen { issues[.inconsistentRead, default: 0] += 1 }
            return SystemSocketSnapshot(readable: true, consistent: consistent, connections: connections, issues: issues)
        }
    }

    private static func decode(_ pcb: xinpcb64, transport: MonitorTransport, state: MonitorTCPState?) -> MonitorConnection? {
        let socket = pcb.xi_socket
        guard socket.xso_family == AF_INET || socket.xso_family == AF_INET6 else { return nil }
        guard socket.xso_protocol == (transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP) else { return nil }
        // so_pgid is a process group, never a PID. Ownership is supplied only by a matching libproc socket.
        guard socket.xso_so != 0 || pcb.inp_gencnt != 0 else { return nil }
        let family: MonitorIPFamily = pcb.inp_vflag & UInt8(INP_IPV4) != 0 && pcb.inp_vflag & UInt8(INP_IPV6) == 0 ? .ipv4 : (socket.xso_family == AF_INET ? .ipv4 : .ipv6)
        let local: String?
        let remote: String?
        if family == .ipv4 {
            local = MonitorAddressDecoder.ipv4(pcb.inp_dependladdr.inp46_local.ia46_addr4)
            remote = MonitorAddressDecoder.ipv4(pcb.inp_dependfaddr.inp46_foreign.ia46_addr4)
        } else {
            local = MonitorAddressDecoder.ipv6(pcb.inp_dependladdr.inp6_local, interfaceIndex: pcb.inp_depend6.inp6_ifindex)
            remote = MonitorAddressDecoder.ipv6(pcb.inp_dependfaddr.inp6_foreign, interfaceIndex: pcb.inp_depend6.inp6_ifindex)
        }
        guard let local, let remote else { return nil }
        return MonitorConnection(id: MonitorConnectionIdentity(process: nil, fileDescriptor: nil,
                                 socketIdentifier: socket.xso_so, generation: pcb.inp_gencnt, transport: transport, family: family), processName: nil,
                                 transport: transport, family: family,
                                 local: MonitorEndpoint(address: local, port: UInt16(bigEndian: pcb.inp_lport)),
                                 remote: MonitorEndpoint(address: remote, port: UInt16(bigEndian: pcb.inp_fport)), tcpState: state)
    }
    private static func failed(_ code: Int32) -> SystemSocketSnapshot {
        SystemSocketSnapshot(readable: false, consistent: false, connections: [],
                             issues: [(code == EPERM || code == EACCES) ? .permissionDenied : (code == ENOMEM ? .limitReached : .unavailable): 1])
    }
    private static func invalid() -> SystemSocketSnapshot {
        SystemSocketSnapshot(readable: false, consistent: false, connections: [], issues: [.inconsistentRead: 1])
    }
}
#endif
