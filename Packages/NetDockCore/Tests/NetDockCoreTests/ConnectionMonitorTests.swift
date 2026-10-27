#if os(macOS)
import XCTest
import Darwin
@testable import NetDockCore

@MainActor final class ConnectionMonitorTests: XCTestCase {
    // Missing or incorrect libproc decoding must fail for sockets we actually own.
    func testCollectsOwnRealTCPAndUDPSocketsInIPv4AndIPv6() async throws {
        let sockets = try MonitorSocketFixture()
        defer { sockets.closeAll() }
        let snapshot = await ConnectionMonitorCollector().collect(processIDs: [getpid()])
        for expected in sockets.expected {
            let record = try XCTUnwrap(snapshot.connections.first { $0.id.fileDescriptor == expected.fd })
            XCTAssertEqual(record.id.process?.pid, getpid())
            XCTAssertGreaterThan(record.id.process?.startSeconds ?? 0, 0)
            XCTAssertGreaterThan(record.id.socketIdentifier, 0)
            XCTAssertEqual(record.transport, expected.transport)
            XCTAssertEqual(record.local.address, expected.address)
            XCTAssertEqual(record.local.port, expected.port)
            if expected.transport == .tcp { XCTAssertEqual(record.tcpState, .listen) }
        }
        XCTAssertEqual(snapshot.coverage.readableProcessCount, 1)
        XCTAssertEqual(snapshot.coverage.readableOtherProcessCount, 0)
        XCTAssertEqual(snapshot.coverage.scope, .ownProcessOnly)
    }
}

extension ConnectionMonitorTests {
    func testPublicPCBLayoutsMatchOwnRealIPv4AndIPv6TCPUDPSockets() throws {
        let sockets = try MonitorSocketFixture()
        defer { sockets.closeAll() }
        for transport in MonitorTransport.allCases {
            let result = SystemSocketSnapshotReader.read(transport)
            XCTAssertTrue(result.readable)
            for expected in sockets.expected where expected.transport == transport {
                let connection = try XCTUnwrap(result.connections.first { $0.local.port == expected.port && $0.local.address == expected.address })
                XCTAssertEqual(connection.transport, transport)
                XCTAssertNil(connection.id.process)
                XCTAssertNil(connection.id.fileDescriptor)
                XCTAssertNil(connection.processName)
                if transport == .tcp { XCTAssertEqual(connection.tcpState, .listen) }
            }
        }
    }

    func testPartialSystemScanDoesNotInventTCPDisappearances() {
        var diff = ConnectionMonitorDiff()
        let tcp = monitorRecord()
        let udp = monitorRecord(pid: 2, transport: .udp)
        let complete = MonitorCoverage(readableProcessCount: 1, systemSamplingAttempted: true, systemSnapshotReadable: true, systemSnapshotComplete: true)
        diff.apply(MonitorSnapshot(collectedAt: Date(timeIntervalSince1970: 100), connections: [tcp, udp], coverage: complete))
        let incomplete = MonitorCoverage(readableProcessCount: 1, systemSamplingAttempted: true, systemSnapshotReadable: true,
                                         systemSnapshotComplete: false, issues: [.unavailable: 1])
        diff.apply(MonitorSnapshot(collectedAt: Date(timeIntervalSince1970: 101), connections: [udp], coverage: incomplete))
        let rows = diff.rows(at: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows.first(where: { $0.id == tcp.id })?.change, .disappeared)
        XCTAssertEqual(rows.first(where: { $0.id == tcp.id })?.lastSeenAt, Date(timeIntervalSince1970: 100))
    }

    func testUnknownOwnershipExportsNullPIDAndKeepsStableSystemIdentity() throws {
        let unknown = MonitorConnection(id: MonitorConnectionIdentity(process: nil, fileDescriptor: nil, socketIdentifier: 123, generation: 9,
                                                                      transport: .udp, family: .ipv6), processName: nil, transport: .udp, family: .ipv6,
                                        local: MonitorEndpoint(address: "::1", port: 55), remote: MonitorEndpoint(address: "::", port: 0), tcpState: nil)
        var diff = ConnectionMonitorDiff()
        let coverage = MonitorCoverage(systemSamplingAttempted: true, systemSnapshotReadable: true, systemSnapshotComplete: true,
                                       systemSocketCount: 1, unattributedConnectionCount: 1)
        let first = MonitorSnapshot(collectedAt: Date(timeIntervalSince1970: 100), connections: [unknown], coverage: coverage)
        diff.apply(first)
        diff.apply(MonitorSnapshot(collectedAt: Date(timeIntervalSince1970: 101), connections: [unknown], coverage: coverage))
        let rows = diff.rows(at: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, unknown.id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ConnectionMonitorExport.data(snapshot: first, rows: rows, format: .json)) as? [String: Any])
        let connections = try XCTUnwrap(object["connections"] as? [[String: Any]])
        XCTAssertTrue(connections.first?["pid"] is NSNull)
        XCTAssertEqual(connections.first?["attribution"] as? String, "unavailable")
        XCTAssertEqual(object["scope"] as? String, "partialSystem")
    }

    func testCollectorMergesPublicSystemSocketsAndMapsOwnedSocketsWithoutDuplicates() async throws {
        let sockets = try MonitorSocketFixture()
        defer { sockets.closeAll() }
        let snapshot = await ConnectionMonitorCollector().collect()
        XCTAssertTrue(snapshot.coverage.systemSnapshotReadable)
        XCTAssertEqual(snapshot.coverage.scope, .partialSystem)
        for expected in sockets.expected {
            let matches = snapshot.connections.filter { $0.local.address == expected.address && $0.local.port == expected.port && $0.transport == expected.transport }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.id.process?.pid, getpid())
            XCTAssertEqual(matches.first?.id.fileDescriptor, expected.fd)
        }
    }

    func testPublicPCBParserRejectsTruncationAndGenerationMismatch() {
        var head = xinpgen(); head.xig_len = UInt32(MemoryLayout<xinpgen>.size); head.xig_gen = 1
        var tail = head; tail.xig_gen = 2
        var data = withUnsafeBytes(of: &head) { Data($0) }
        data.append(withUnsafeBytes(of: &tail) { Data($0) })
        let changed = SystemSocketSnapshotReader.parse(data, transport: .tcp)
        XCTAssertTrue(changed.readable)
        XCTAssertFalse(changed.consistent)
        XCTAssertEqual(changed.issues[.inconsistentRead], 1)
        data.removeLast()
        let truncated = SystemSocketSnapshotReader.parse(data, transport: .tcp)
        XCTAssertFalse(truncated.readable)
        XCTAssertEqual(truncated.issues[.inconsistentRead], 1)
    }

    func testEstablishedTCPAndConnectedUDPDecodeRealRemoteEndpoints() async throws {
        let sockets = try MonitorSocketFixture()
        var extra: [Int32] = []
        defer { extra.forEach { Darwin.close($0) }; sockets.closeAll() }
        for expected in sockets.expected {
            let family = expected.address == "::1" ? AF_INET6 : AF_INET
            let client = socket(family, expected.transport == .tcp ? SOCK_STREAM : SOCK_DGRAM,
                                expected.transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP)
            guard client >= 0 else { throw POSIXError(.EIO) }; extra.append(client)
            var address = sockaddr_storage(); var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let got = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(expected.fd, $0, &size) } }
            guard got == 0 else { throw POSIXError(.EIO) }
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, size) } }
            guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if expected.transport == .tcp {
                let accepted = Darwin.accept(expected.fd, nil, nil)
                guard accepted >= 0 else { throw POSIXError(.EIO) }; extra.append(accepted)
            }
            let own = await ConnectionMonitorCollector().collect(processIDs: [getpid()])
            let record = try XCTUnwrap(own.connections.first { $0.id.fileDescriptor == client })
            XCTAssertEqual(record.remote.address, expected.address)
            XCTAssertEqual(record.remote.port, expected.port)
            XCTAssertEqual(record.local.address, expected.address)
            XCTAssertGreaterThan(record.local.port, 0)
            if expected.transport == .tcp { XCTAssertEqual(record.tcpState, .established) }
            let system = SystemSocketSnapshotReader.read(expected.transport)
            let systemRecord = try XCTUnwrap(system.connections.first { $0.local.port == record.local.port && $0.remote.port == expected.port })
            XCTAssertEqual(systemRecord.remote.address, expected.address)
            XCTAssertEqual(systemRecord.local.address, expected.address)
            if expected.transport == .tcp { XCTAssertEqual(systemRecord.tcpState, .established) }
        }
    }

    // Reusing a PID or FD must create a new row, while TCP state changes keep the original identity.
    func testDiffKeepsIdentityHighlightsStateAndExpiresDisappearances() throws {
        let first = monitorRecord()
        var diff = ConnectionMonitorDiff()
        diff.apply(monitorSnapshot([first], at: 100))
        XCTAssertEqual(diff.rows(at: Date(timeIntervalSince1970: 100)).first?.change, .added)
        let established = monitorRecord(state: .established)
        diff.apply(monitorSnapshot([established], at: 102))
        let changed = try XCTUnwrap(diff.rows(at: Date(timeIntervalSince1970: 102)).first)
        XCTAssertEqual(changed.id, first.id)
        XCTAssertEqual(changed.change, .changed)
        XCTAssertEqual(changed.firstSeenAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(changed.lastSeenAt, Date(timeIntervalSince1970: 102))
        diff.apply(monitorSnapshot([], at: 103))
        diff.apply(monitorSnapshot([], at: 106))
        XCTAssertEqual(diff.rows(at: Date(timeIntervalSince1970: 106)).first?.change, .disappeared)
        XCTAssertTrue(diff.rows(at: Date(timeIntervalSince1970: 109)).isEmpty)
        diff.apply(monitorSnapshot([monitorRecord(socket: 999)], at: 110))
        XCTAssertEqual(diff.rows(at: Date(timeIntervalSince1970: 110)).count, 1)
        XCTAssertEqual(diff.rows(at: Date(timeIntervalSince1970: 110)).first?.change, .added)
    }

    func testDiffTreatsPIDAndFDReuseAsNewConnectionsAndBoundsHistory() {
        var diff = ConnectionMonitorDiff(maximumRows: 3)
        diff.apply(monitorSnapshot([monitorRecord()], at: 100))
        diff.apply(monitorSnapshot([monitorRecord(birth: 11), monitorRecord(pid: 2), monitorRecord(pid: 3)], at: 101))
        let rows = diff.rows(at: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.change == .added })
        XCTAssertFalse(rows.contains { $0.id == monitorRecord().id })
    }

    func testUnreadableScanPreservesLastKnownRowsWithoutInventingDisappearances() {
        var diff = ConnectionMonitorDiff()
        diff.apply(monitorSnapshot([monitorRecord()], at: 100))
        diff.apply(MonitorSnapshot(collectedAt: Date(timeIntervalSince1970: 101), connections: [],
                                   coverage: MonitorCoverage(issues: [.permissionDenied: 1])))
        let rows = diff.rows(at: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotEqual(rows.first?.change, .disappeared)
        XCTAssertEqual(rows.first?.lastSeenAt, Date(timeIntervalSince1970: 100))
    }

    func testSearchProtocolLocalPortAndMultiColumnNumericSorting() {
        var diff = ConnectionMonitorDiff()
        diff.apply(monitorSnapshot([
            monitorRecord(pid: 3, name: "测试 Worker", port: 100),
            monitorRecord(pid: 2, name: "测试 Worker", port: 20),
            monitorRecord(pid: 1, name: "测试 Worker", port: 20),
            monitorRecord(pid: 4, name: "Other", port: 20, transport: .udp)
        ], at: 100))
        let rows = diff.rows(at: Date(timeIntervalSince1970: 100))
        let sorted = MonitorQuery.rows(rows, filter: MonitorFilter(search: "worker 测试", transport: .tcp),
                                       sort: [MonitorRowComparator(.localPort), MonitorRowComparator(.pid, order: .reverse)])
        XCTAssertEqual(sorted.map { $0.connection.id.process?.pid }, [2, 1, 3])
        let port = MonitorQuery.rows(rows, filter: MonitorFilter(transport: .udp, localPort: 20), sort: [])
        XCTAssertEqual(port.map { $0.connection.id.process?.pid }, [4])
        XCTAssertTrue(MonitorQuery.rows(rows, filter: MonitorFilter(localPort: 1234), sort: []).isEmpty)
    }

    func testSearchMatchesNamesBothPortsAndCombinedTermsWithoutRequiringAttribution() {
        let local = monitorRecord(name: "Example Service", port: 49152)
        let remote = MonitorConnection(
            id: MonitorConnectionIdentity(process: nil, fileDescriptor: nil, socketIdentifier: 999, generation: 1),
            processName: nil, transport: .tcp, family: .ipv4,
            local: MonitorEndpoint(address: "127.0.0.1", port: 50000),
            remote: MonitorEndpoint(address: "192.0.2.1", port: 49152), tcpState: .established)
        var diff = ConnectionMonitorDiff()
        diff.apply(monitorSnapshot([local, remote], at: 100))
        let rows = diff.rows(at: Date(timeIntervalSince1970: 100))
        func matches(_ search: String, transport: MonitorTransport? = nil, localPort: UInt16? = nil) -> Set<MonitorConnectionIdentity> {
            Set(MonitorQuery.rows(rows, filter: MonitorFilter(search: search, transport: transport, localPort: localPort), sort: []).map(\.id))
        }
        XCTAssertEqual(matches("  eXAMPLE service \t49152  "), [local.id])
        XCTAssertEqual(matches("49152"), [local.id, remote.id])
        XCTAssertEqual(matches("192.0.2.1 49152 established TCP"), [remote.id])
        XCTAssertTrue(matches("Example 50000").isEmpty)
        XCTAssertTrue(matches("49152", transport: .udp).isEmpty)
        XCTAssertEqual(matches("49152", localPort: 50000), [remote.id])
        XCTAssertEqual(matches(" \n "), [local.id, remote.id])
    }

    func testJSONAndCSVEscapeUntrustedProcessNamesAndIncludeVisibility() throws {
        let name = "=formula,\"中文\"\r\nnext"
        let snapshot = monitorSnapshot([monitorRecord(name: name)], at: 100)
        var diff = ConnectionMonitorDiff(); diff.apply(snapshot)
        let rows = diff.rows(at: Date(timeIntervalSince1970: 100))
        let json = try ConnectionMonitorExport.data(snapshot: snapshot, rows: rows, format: .json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["scope"] as? String, "ownProcessOnly")
        let records = try XCTUnwrap(object["connections"] as? [[String: Any]])
        XCTAssertEqual(records.first?["process"] as? String, name)
        XCTAssertEqual(records.first?["localPort"] as? Int, 80)
        XCTAssertNil(records.first?["socketIdentifier"])
        let csv = String(decoding: try ConnectionMonitorExport.data(snapshot: snapshot, rows: rows, format: .csv), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"'=formula,\"\"中文\"\"\r\nnext\""))
        XCTAssertTrue(csv.contains("ownProcessOnly"))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }
}

private func monitorRecord(pid: Int32 = 1, birth: UInt64 = 10, socket: UInt64 = 100,
                           name: String = "NetDock", port: UInt16 = 80, transport: MonitorTransport = .tcp,
                           state: MonitorTCPState = .listen) -> MonitorConnection {
    MonitorConnection(id: MonitorConnectionIdentity(process: MonitorProcessIdentity(pid: pid, startSeconds: birth, startMicroseconds: 3),
                                                    fileDescriptor: 5, socketIdentifier: socket, generation: 7, transport: transport),
                      processName: name, transport: transport, family: .ipv4,
                      local: MonitorEndpoint(address: "127.0.0.1", port: port), remote: MonitorEndpoint(address: "0.0.0.0", port: 0),
                      tcpState: transport == .tcp ? state : nil)
}
private func monitorSnapshot(_ connections: [MonitorConnection], at seconds: TimeInterval) -> MonitorSnapshot {
    MonitorSnapshot(collectedAt: Date(timeIntervalSince1970: seconds), connections: connections,
                    coverage: MonitorCoverage(enumeratedProcessCount: 1, readableProcessCount: 1))
}

private final class MonitorSocketFixture {
    struct Expected { let fd: Int32; let transport: MonitorTransport; let address: String; let port: UInt16 }
    private(set) var expected: [Expected] = []
    init() throws {
        do {
            for family in [AF_INET, AF_INET6] {
                for transport in [MonitorTransport.tcp, .udp] {
                    let fd = socket(family, transport == .tcp ? SOCK_STREAM : SOCK_DGRAM,
                                    transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP)
                    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    var saved = false
                    defer { if !saved { Darwin.close(fd) } }
                    var size: socklen_t
                    let port: UInt16
                    let result: Int32
                    if family == AF_INET {
                        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
                        size = socklen_t(MemoryLayout<sockaddr_in>.size)
                        result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) } }
                        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        let got = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
                        guard got == 0 else { throw POSIXError(.EIO) }
                        port = UInt16(bigEndian: address.sin_port)
                    } else {
                        var address = sockaddr_in6(); address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                        address.sin6_family = sa_family_t(AF_INET6); address.sin6_addr = in6addr_loopback
                        size = socklen_t(MemoryLayout<sockaddr_in6>.size)
                        result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) } }
                        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        let got = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
                        guard got == 0 else { throw POSIXError(.EIO) }
                        port = UInt16(bigEndian: address.sin6_port)
                    }
                    if transport == .tcp && listen(fd, 1) != 0 { throw POSIXError(.EIO) }
                    expected.append(Expected(fd: fd, transport: transport, address: family == AF_INET ? "127.0.0.1" : "::1", port: port))
                    saved = true
                }
            }
        } catch { closeAll(); throw error }
    }
    func closeAll() { for item in expected { Darwin.close(item.fd) }; expected = [] }
}
#endif
