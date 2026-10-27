import XCTest
import Darwin
@testable import NetDockCore

private final class EventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NetworkEvent] = []
    func append(_ event: NetworkEvent) { lock.lock(); events.append(event); lock.unlock() }
    var snapshot: [NetworkEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var received: Data {
        snapshot.reduce(into: Data()) { data, event in if case .received(let transfer) = event { data.append(transfer.payload) } }
    }
    var peerIDs: [UUID] { snapshot.compactMap { if case .peerJoined(let peer) = $0 { peer.id } else { nil } } }
    func hasState(_ state: ConnectionState) -> Bool { snapshot.contains { if case .stateChanged(state) = $0 { true } else { false } } }
    func wait(_ description: String, timeout: TimeInterval = 5, until condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "TCPIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out: \(description); events: \(snapshot)"]) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
final class TCPIntegrationTests: XCTestCase {
    private func freePort() throws -> UInt16 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        defer { close(socketFD) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) } }
        guard result == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: address.sin_port)
    }

    private func server(port: UInt16, probe: EventProbe) async throws -> TCPService {
        let service = TCPService(mode: .tcpServer) { probe.append($0) }
        try await service.start(SessionConfig(name: "Server", mode: .tcpServer, localPort: port))
        try await probe.wait("listener ready") { probe.hasState(.listening) }
        return service
    }
    private func client(port: UInt16, probe: EventProbe, host: String = "127.0.0.1") async throws -> TCPService {
        let service = TCPService(mode: .tcpClient) { probe.append($0) }
        try await service.start(SessionConfig(name: "Client", host: host, remotePort: port))
        try await probe.wait("client ready") { probe.hasState(.ready) }
        return service
    }

    func testBidirectionalBinaryAndActualEndpoints() async throws {
        let port = try freePort(); let sp = EventProbe(); let cp = EventProbe()
        let server = try await server(port: port, probe: sp)
        let client = try await client(port: port, probe: cp)
        try await sp.wait("accepted peer") { sp.peerIDs.count == 1 }
        let data = Data([0x00, 0xFF, 0xC3, 0x28])
        let sent = try await client.send(data)
        XCTAssertNil(sent.first?.error)
        try await sp.wait("server binary receive") { sp.received.count == data.count }
        XCTAssertEqual(sp.received, data)
        _ = try await server.send(data, to: .allPeers)
        try await cp.wait("client binary receive") { cp.received.count == data.count }
        XCTAssertEqual(cp.received, data)
        let transfers = sp.snapshot.compactMap { if case .received(let t) = $0 { t } else { nil } }
        XCTAssertTrue(transfers.first?.remoteEndpoint.hasPrefix("127.0.0.1:") == true)
        XCTAssertTrue(transfers.first?.localEndpoint?.hasSuffix(":\(port)") == true)
        await client.stop(); await server.stop()
    }

    func testThreeClientsTargetedBroadcastAndIndependentDisconnect() async throws {
        let port = try freePort(); let sp = EventProbe()
        let server = try await server(port: port, probe: sp)
        let probes = [EventProbe(), EventProbe(), EventProbe()]
        var clients: [TCPService] = []
        for probe in probes { clients.append(try await client(port: port, probe: probe)) }
        try await sp.wait("three peers") { sp.peerIDs.count == 3 }
        XCTAssertEqual(Set(sp.peerIDs).count, 3)
        // Identify each peer by real inbound content, independent of callback arrival order.
        for (index, client) in clients.enumerated() { _ = try await client.send(Data([UInt8(index)])) }
        try await sp.wait("peer identifiers") { sp.received.count == 3 }
        let identified = sp.snapshot.compactMap { event -> (UInt8, UUID)? in
            if case .received(let t) = event, let byte = t.payload.first, let id = t.peerID { return (byte, id) }
            return nil
        }
        let ids = Dictionary(uniqueKeysWithValues: identified)
        guard let second = ids[1] else { return XCTFail("Missing real peer identity") }
        _ = try await server.send(Data("only-second".utf8), to: .peer(second))
        try await probes[1].wait("targeted data") { probes[1].received.count == 11 }
        XCTAssertEqual(probes[0].received.count, 0); XCTAssertEqual(probes[2].received.count, 0)
        let result = try await server.send(Data([0x42]), to: .allPeers)
        XCTAssertEqual(result.count, 3); XCTAssertTrue(result.allSatisfy { $0.error == nil })
        for (index, probe) in probes.enumerated() {
            try await probe.wait("broadcast \(index)") { probe.received.count == (index == 1 ? 12 : 1) }
        }
        await server.disconnect(peerID: second)
        try await probes[1].wait("independent disconnect") { probes[1].hasState(.stopped) || probes[1].hasState(.failed) }
        XCTAssertFalse(probes[0].hasState(.stopped)); XCTAssertFalse(probes[2].hasState(.stopped))
        XCTAssertFalse(sp.hasState(.failed))
        do { _ = try await server.send(Data([1]), to: .peer(second)); XCTFail("Disconnected peer send must fail") }
        catch { XCTAssertEqual((error as? NetDockError)?.code, .peerMissing) }
        for client in clients { await client.stop() }; await server.stop()
    }

    func testOneByte64KiBAndOneMiBWithoutMessageBoundaryAssumptions() async throws {
        let port = try freePort(); let sp = EventProbe(); let cp = EventProbe()
        let server = try await server(port: port, probe: sp)
        let client = try await client(port: port, probe: cp)
        var expected = Data()
        for size in [1, 65_536, 1_048_576] {
            let data = Data((0..<size).map { UInt8($0 % 251) }); expected.append(data)
            _ = try await client.send(data)
        }
        let expectedCount = expected.count
        try await sp.wait("large stream", timeout: 10) { sp.received.count == expectedCount }
        XCTAssertEqual(sp.received, expected)
        _ = try await server.send(expected, to: .allPeers)
        try await cp.wait("large reply", timeout: 10) { cp.received.count == expectedCount }
        XCTAssertEqual(cp.received, expected)
        await client.stop(); await server.stop()
    }

    func testRefusedAndPortInUseFailVisibly() async throws {
        let port = try freePort(); let cp = EventProbe()
        let client = TCPService(mode: .tcpClient) { cp.append($0) }
        try await client.start(SessionConfig(name: "Refused", remotePort: port))
        try await cp.wait("refused") { cp.hasState(.failed) }
        XCTAssertTrue(cp.snapshot.contains { if case .error(let e) = $0 { e.code == .refused } else { false } })
        let sp = EventProbe(); let occupied = EventProbe()
        let server = try await server(port: port, probe: sp)
        let other = TCPService(mode: .tcpServer) { occupied.append($0) }
        try? await other.start(SessionConfig(name: "Occupied", mode: .tcpServer, localPort: port))
        try await occupied.wait("occupied port") { occupied.hasState(.failed) }
        XCTAssertTrue(occupied.snapshot.contains { if case .error(let e) = $0 { e.code == .addressInUse } else { false } })
        await client.stop(); await other.stop(); await server.stop()
    }

    func testDNSFailureHasReadableCategory() async throws {
        let probe = EventProbe(); let client = TCPService(mode: .tcpClient, connectionTimeout: 4) { probe.append($0) }
        try await client.start(SessionConfig(name: "DNS", host: "netdock-does-not-exist.invalid"))
        try await probe.wait("DNS failure", timeout: 6) { probe.hasState(.failed) }
        XCTAssertTrue(probe.snapshot.contains { if case .error(let e) = $0 { e.code == .dns } else { false } })
        await client.stop()
    }

    func testIdempotentStartStopAndRestartDoesNotAcceptStaleCallbacks() async throws {
        let port = try freePort(); let probe = EventProbe()
        let server = try await server(port: port, probe: probe)
        let config = SessionConfig(name: "Server", mode: .tcpServer, localPort: port)
        try await server.start(config)
        XCTAssertEqual(probe.snapshot.filter { if case .stateChanged(.connecting) = $0 { true } else { false } }.count, 1)
        await server.stop(); await server.stop()
        try await server.start(config)
        try await probe.wait("second listener ready") {
            probe.snapshot.filter { if case .stateChanged(.listening) = $0 { true } else { false } }.count == 2
        }
        let cp = EventProbe(); let client = try await client(port: port, probe: cp)
        _ = try await client.send(Data([0xAB]))
        try await probe.wait("data after restart") { probe.received == Data([0xAB]) }
        XCTAssertFalse(probe.hasState(.failed))
        await server.stop()
        try await cp.wait("stop listener closes accepted peer") { cp.hasState(.stopped) || cp.hasState(.failed) }
        await client.stop()
    }

    func testNotReadyAndEmptySendsThrowInsteadOfDropping() async throws {
        let client = TCPService(mode: .tcpClient) { _ in }
        do { _ = try await client.send(Data([1])); XCTFail("Must throw before ready") }
        catch { XCTAssertEqual((error as? NetDockError)?.code, .notReady) }
        do { _ = try await client.send(Data()); XCTFail("Must reject empty payload") }
        catch { XCTAssertEqual((error as? NetDockError)?.code, .emptyPayload) }
    }

    func testIPv6Loopback() async throws {
        let port = try freePort(); let sp = EventProbe(); let cp = EventProbe()
        let server = try await server(port: port, probe: sp)
        let client = try await client(port: port, probe: cp, host: "[::1]")
        _ = try await client.send(Data("IPv6".utf8))
        try await sp.wait("IPv6 receive") { sp.received == Data("IPv6".utf8) }
        await client.stop(); await server.stop()
    }

    func testGracefulEOFAndResetLeaveListenerRunning() async throws {
        let port = try freePort(); let probe = EventProbe()
        let server = try await server(port: port, probe: probe)
        func rawClient() throws -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
            return fd
        }
        let graceful = try rawClient()
        try await probe.wait("graceful client joined") { probe.peerIDs.count == 1 }
        shutdown(graceful, SHUT_WR); close(graceful)
        try await probe.wait("real FIN") {
            probe.snapshot.contains { if case .system("event.remoteClosed") = $0 { true } else { false } }
        }
        let reset = try rawClient()
        try await probe.wait("reset client joined") { probe.peerIDs.count == 2 }
        var option = linger(l_onoff: 1, l_linger: 0)
        XCTAssertEqual(setsockopt(reset, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size)), 0)
        close(reset)
        try await probe.wait("reset reported") {
            probe.snapshot.contains { if case .error(let error) = $0 { error.detail.contains("54") || error.detail.contains("reset") } else { false } }
        }
        XCTAssertFalse(probe.hasState(.failed))
        XCTAssertEqual(probe.snapshot.filter { if case .peerLeft = $0 { true } else { false } }.count, 2)
        await server.stop()
    }

    func testEmptyBroadcastAndSendBackpressure() async throws {
        let port = try freePort(); let sp = EventProbe(); let cp = EventProbe()
        let server = try await server(port: port, probe: sp)
        do { _ = try await server.send(Data([1]), to: .allPeers); XCTFail("Empty broadcast must fail") }
        catch { XCTAssertEqual((error as? NetDockError)?.code, .noPeers) }
        let client = try await client(port: port, probe: cp)
        do {
            _ = try await client.send(Data(repeating: 0, count: 16 * 1_024 * 1_024 + 1))
            XCTFail("Oversized pending send must fail")
        } catch { XCTAssertEqual((error as? NetDockError)?.code, .sendQueueFull) }
        _ = try await client.send(Data([0x42]))
        try await sp.wait("usable after rejected send") { sp.received == Data([0x42]) }
        await client.stop(); await server.stop()
    }
}
