#if os(macOS)
import Foundation
import Darwin

/// Synchronous libproc work stays on this actor's executor, never the main actor.
/// A scan has no suspension points, so concurrent callers cannot overlap scans.
public actor ConnectionMonitorCollector {
    public static let maximumConnections = 20_000
    private let maximumProcesses = 65_536
    private let maximumDescriptors = 65_536
    public init() {}

    public func collect() -> MonitorSnapshot {
        var coverage = MonitorCoverage()
        let pids = processIDs(coverage: &coverage)
        let owned = scan(pids, coverage: coverage)
        coverage = owned.coverage
        coverage.systemSamplingAttempted = true
        let system = MonitorTransport.allCases.map { SystemSocketSnapshotReader.read($0) }
        coverage.systemSnapshotReadable = system.contains { $0.readable }
        coverage.systemSnapshotComplete = system.allSatisfy { $0.readable && $0.consistent }
        for sample in system {
            coverage.systemSocketCount += sample.connections.count
            for (issue, count) in sample.issues { coverage.issues[issue, default: 0] += count }
        }
        var connections = owned.connections
        var known = Set(connections.map(MonitorSocketKey.init))
        for connection in system.flatMap(\.connections) {
            guard known.insert(MonitorSocketKey(connection)).inserted else { continue }
            if connections.count >= Self.maximumConnections {
                coverage.issues[.limitReached, default: 0] += 1
                coverage.systemSnapshotComplete = false
                break
            }
            connections.append(connection)
            coverage.unattributedConnectionCount += 1
        }
        return MonitorSnapshot(collectedAt: .now, connections: connections, coverage: coverage)
    }

    // A narrow internal entry point allows real-socket tests without depending on unrelated processes.
    func collect(processIDs: [Int32]) -> MonitorSnapshot {
        scan(Array(Set(processIDs)).sorted(), coverage: MonitorCoverage())
    }

    private func processIDs(coverage: inout MonitorCoverage) -> [Int32] {
        errno = 0
        let estimate = proc_listallpids(nil, 0)
        if estimate <= 0 {
            record(error: errno, coverage: &coverage)
            return [getpid()] // App Sandbox can deny system enumeration while permitting our own descriptors.
        }
        var capacity = min(maximumProcesses, Int(estimate) + 128)
        var result: [Int32] = []
        for attempt in 0..<2 {
            var pids = [Int32](repeating: 0, count: capacity)
            errno = 0
            let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            guard count > 0 else { record(error: errno, coverage: &coverage); return [getpid()] }
            result = Array(pids.prefix(min(Int(count), capacity))).filter { $0 > 0 }
            if Int(count) < capacity { break }
            if capacity == maximumProcesses || attempt == 1 { coverage.issues[.limitReached, default: 0] += 1; break }
            capacity = min(maximumProcesses, capacity * 2)
        }
        return Array(Set(result + [getpid()])).sorted()
    }

    private func scan(_ pids: [Int32], coverage initial: MonitorCoverage) -> MonitorSnapshot {
        var coverage = initial
        coverage.enumeratedProcessCount = pids.count
        var connections: [MonitorConnection] = []
        for pid in pids.prefix(maximumProcesses) {
            if Task.isCancelled { coverage.issues[.cancelled, default: 0] += 1; break }
            guard let before = processInfo(pid, coverage: &coverage),
                  let descriptors = descriptors(pid, coverage: &coverage) else { continue }
            let identity = processIdentity(before)
            let name = processName(before)
            var processConnections: [MonitorConnection] = []
            for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
                if Task.isCancelled { coverage.issues[.cancelled, default: 0] += 1; break }
                var info = socket_fdinfo()
                errno = 0
                let size = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                guard size == MemoryLayout<socket_fdinfo>.size else {
                    record(error: size <= 0 ? errno : 0, coverage: &coverage); continue
                }
                if let item = decode(info.psi, process: identity, name: name, fd: descriptor.proc_fd) {
                    processConnections.append(item)
                    if processConnections.count + connections.count >= Self.maximumConnections {
                        coverage.issues[.limitReached, default: 0] += 1; break
                    }
                }
            }
            // PIDs may be recycled while descriptors are read. Never assign a replacement process's sockets to the old process.
            guard let after = processInfo(pid, coverage: &coverage), processIdentity(after) == identity else {
                coverage.issues[.inconsistentRead, default: 0] += 1; continue
            }
            coverage.readableProcessCount += 1
            if pid != getpid() { coverage.readableOtherProcessCount += 1 }
            connections.append(contentsOf: processConnections)
            if connections.count >= Self.maximumConnections { break }
        }
        if pids.count > maximumProcesses { coverage.issues[.limitReached, default: 0] += 1 }
        return MonitorSnapshot(collectedAt: .now, connections: connections, coverage: coverage)
    }

    private func processInfo(_ pid: Int32, coverage: inout MonitorCoverage) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        errno = 0
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { record(error: size <= 0 ? errno : 0, coverage: &coverage); return nil }
        return info
    }

    private func descriptors(_ pid: Int32, coverage: inout MonitorCoverage) -> [proc_fdinfo]? {
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if needed < 0 || (needed == 0 && errno != 0) { record(error: errno, coverage: &coverage); return nil }
        if needed == 0 { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var capacity = min(maximumDescriptors, Int(needed) / stride + 32)
        for attempt in 0..<2 {
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            errno = 0
            let size = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard size >= 0 && (size > 0 || errno == 0) else { record(error: errno, coverage: &coverage); return nil }
            guard Int(size) % stride == 0 else { coverage.issues[.inconsistentRead, default: 0] += 1; return nil }
            let count = min(capacity, Int(size) / stride)
            if count < capacity { return Array(fds.prefix(count)) }
            if capacity == maximumDescriptors || attempt == 1 {
                coverage.issues[.limitReached, default: 0] += 1; return Array(fds.prefix(count))
            }
            capacity = min(maximumDescriptors, capacity * 2)
        }
        return []
    }

    private func decode(_ socket: socket_info, process: MonitorProcessIdentity, name: String, fd: Int32) -> MonitorConnection? {
        guard socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { return nil }
        let transport: MonitorTransport
        let address: in_sockinfo
        let state: MonitorTCPState?
        if socket.soi_protocol == IPPROTO_TCP && socket.soi_kind == SOCKINFO_TCP {
            transport = .tcp; address = socket.soi_proto.pri_tcp.tcpsi_ini
            state = MonitorTCPState(rawValue: socket.soi_proto.pri_tcp.tcpsi_state) ?? .unknown
        } else if socket.soi_protocol == IPPROTO_UDP && socket.soi_kind == SOCKINFO_IN {
            transport = .udp; address = socket.soi_proto.pri_in; state = nil
        } else { return nil }
        // A dual-stack IPv6 socket can contain an IPv4 peer. The kernel vflag describes the stored address format.
        let family: MonitorIPFamily = address.insi_vflag & UInt8(INI_IPV4) != 0 && address.insi_vflag & UInt8(INI_IPV6) == 0 ? .ipv4 : (socket.soi_family == AF_INET ? .ipv4 : .ipv6)
        let local: String?
        let remote: String?
        if family == .ipv4 {
            local = MonitorAddressDecoder.ipv4(address.insi_laddr.ina_46.i46a_addr4)
            remote = MonitorAddressDecoder.ipv4(address.insi_faddr.ina_46.i46a_addr4)
        } else {
            local = MonitorAddressDecoder.ipv6(address.insi_laddr.ina_6, interfaceIndex: address.insi_v6.in6_ifindex)
            remote = MonitorAddressDecoder.ipv6(address.insi_faddr.ina_6, interfaceIndex: address.insi_v6.in6_ifindex)
        }
        guard let local, let remote else { return nil }
        let id = MonitorConnectionIdentity(process: process, fileDescriptor: fd,
                                           socketIdentifier: socket.soi_so, generation: address.insi_gencnt, transport: transport, family: family)
        return MonitorConnection(id: id, processName: name, transport: transport, family: family,
                                 local: MonitorEndpoint(address: local, port: UInt16(bigEndian: UInt16(truncatingIfNeeded: address.insi_lport))),
                                 remote: MonitorEndpoint(address: remote, port: UInt16(bigEndian: UInt16(truncatingIfNeeded: address.insi_fport))), tcpState: state)
    }

    private func processIdentity(_ info: proc_bsdinfo) -> MonitorProcessIdentity {
        MonitorProcessIdentity(pid: Int32(bitPattern: info.pbi_pid), startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
    private func processName(_ original: proc_bsdinfo) -> String {
        var info = original
        let name = withUnsafeBytes(of: &info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return name.isEmpty ? withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : name
    }
    private func record(error: Int32, coverage: inout MonitorCoverage) {
        let category: MonitorIssue
        switch error {
        case EPERM, EACCES: category = .permissionDenied
        case ESRCH, ENOENT, EBADF: category = .processEnded
        case 0: category = .inconsistentRead
        default: category = .unavailable
        }
        coverage.issues[category, default: 0] += 1
    }
}

private struct MonitorSocketKey: Hashable {
    let token: UInt64
    let generation: UInt64
    let transport: MonitorTransport
    let family: MonitorIPFamily
    init(_ connection: MonitorConnection) {
        token = connection.id.socketIdentifier; generation = connection.id.generation
        transport = connection.transport; family = connection.family
    }
}
#endif
