import XCTest
import Darwin
@testable import NetDockCore

private final class DatagramProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NetworkEvent] = []
    func append(_ event: NetworkEvent) { lock.lock(); events.append(event); lock.unlock() }
    var snapshot: [NetworkEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var received: [Transfer] { snapshot.compactMap { if case .received(let t) = $0 { t } else { nil } } }
    var peers: [PeerInfo] { snapshot.compactMap { if case .peerJoined(let p) = $0 { p } else { nil } } }
    func hasState(_ state: ConnectionState) -> Bool { snapshot.contains { if case .stateChanged(state) = $0 { true } else { false } } }
    func wait(_ label: String, until condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "UDPTests: \(label)", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor final class UDPIntegrationTests: XCTestCase {
    private var services: [UDPService] = []
    override func tearDown() async throws {
        for service in services { await service.stop() }
        services = []
    }
    private func port() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard result == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: address.sin_port)
    }
    private func start(_ config: SessionConfig, _ probe: DatagramProbe) async throws -> UDPService {
        let service = UDPService(mode: config.mode, operationTimeout: 2) { probe.append($0) }
        services.append(service); try await service.start(config)
        try await probe.wait("ready") { probe.hasState(config.mode.isServer ? .listening : .ready) }
        return service
    }
    func testBinaryChineseBoundPortAndDatagramBoundaries() async throws {
        let serverPort = try port(); let localPort = try port(); let sp = DatagramProbe(); let cp = DatagramProbe()
        let server = try await start(SessionConfig(name: "server", mode: .udpServer, localPort: serverPort), sp)
        let client = try await start(SessionConfig(name: "client", mode: .udpClient, remotePort: serverPort, localPort: localPort), cp)
        let payloads = [Data("中文报文🌊".utf8), Data([0, 0xFF, 0, 0xFE]), Data([1])]
        for data in payloads { let result = try await client.send(data); XCTAssertNil(result.first?.error) }
        try await sp.wait("3 datagrams") { sp.received.count == 3 }
        XCTAssertEqual(sp.received.map(\.payload), payloads)
        XCTAssertTrue(sp.received.allSatisfy { $0.remoteEndpoint == "127.0.0.1:\(localPort)" && $0.localEndpoint?.hasSuffix(":\(serverPort)") == true })
        let source = try XCTUnwrap(sp.received.first?.peerID)
        _ = try await server.send(payloads[1], to: .peer(source))
        try await cp.wait("reply") { cp.received.count == 1 }
        XCTAssertEqual(cp.received[0].payload, payloads[1])
        XCTAssertEqual(cp.received[0].remoteEndpoint, "127.0.0.1:\(serverPort)")
        XCTAssertTrue(cp.received[0].localEndpoint?.hasSuffix(":\(localPort)") == true)
        XCTAssertFalse(cp.hasState(.connecting))
    }
    func testIPv6AndExplicitLocalAddress() async throws {
        let p = try port(); let sp = DatagramProbe(); let cp = DatagramProbe()
        var config = SessionConfig(name: "v6 server", mode: .udpServer, localPort: p); config.localHost = "::1"
        let server = try await start(config, sp)
        var clientConfig = SessionConfig(name: "v6 client", mode: .udpClient, host: "[::1]", remotePort: p, localPort: 0)
        clientConfig.localHost = "::1"
        let client = try await start(clientConfig, cp)
        _ = try await client.send(Data([0, 255]))
        try await sp.wait("v6 datagram") { sp.received.count == 1 }
        XCTAssertTrue(sp.received[0].remoteEndpoint.hasPrefix("[::1]:"))
        _ = try await server.send(Data([255, 0]), to: .peer(try XCTUnwrap(sp.received[0].peerID)))
        try await cp.wait("v6 reply") { cp.received.count == 1 }
        XCTAssertEqual(cp.received[0].payload, Data([255, 0]))
    }
    func testIndependentSourcesTargetedReplyAndSessionIsolation() async throws {
        let p = try port(); let sp = DatagramProbe()
        let server = try await start(SessionConfig(name: "server", mode: .udpServer, localPort: p), sp)
        let probes = [DatagramProbe(), DatagramProbe()]
        var clients: [UDPService] = []
        for probe in probes { clients.append(try await start(SessionConfig(name: "client", mode: .udpClient, remotePort: p, localPort: 0), probe)) }
        for (i, client) in clients.enumerated() { _ = try await client.send(Data([UInt8(i)])) }
        try await sp.wait("2 sources") { sp.received.count == 2 }
        let source = try XCTUnwrap(sp.received.first(where: { $0.payload == Data([1]) })?.peerID)
        _ = try await server.send(Data([42]), to: .peer(source))
        try await probes[1].wait("only second") { probes[1].received.count == 1 }
        XCTAssertEqual(probes[0].received.count, 0)
        await clients[0].stop()
        _ = try await clients[1].send(Data([2]))
        try await sp.wait("other source survives") { sp.received.count == 3 }
        XCTAssertFalse(sp.hasState(.failed))
    }
    func testServerExplicitDestinationKeepsListeningPort() async throws {
        let p = try port(); let p2 = try port(); let first = DatagramProbe(); let second = DatagramProbe()
        let sender = try await start(SessionConfig(name: "sender", mode: .udpServer, localPort: p), first)
        let recipient = try await start(SessionConfig(name: "recipient", mode: .udpServer, localPort: p2), second)
        _ = try await sender.send(Data([0, 255]), to: .endpoint(host: "127.0.0.1", port: p2))
        try await second.wait("explicit destination") { second.received.count == 1 }
        XCTAssertEqual(second.received[0].remoteEndpoint, "127.0.0.1:\(p)")
        _ = try await recipient.send(Data([9]), to: .peer(try XCTUnwrap(second.received[0].peerID)))
        try await first.wait("explicit reply") { first.received.count == 1 }
        XCTAssertEqual(first.received[0].payload, Data([9]))
    }
    func testOccupiedPortAndImmediateRestart() async throws {
        let p = try port(); let sp = DatagramProbe()
        let config = SessionConfig(name: "server", mode: .udpServer, localPort: p)
        let server = try await start(config, sp)
        let occupied = DatagramProbe(); let other = UDPService(mode: .udpServer) { occupied.append($0) }; services.append(other)
        try? await other.start(config)
        try await occupied.wait("port occupied") { occupied.hasState(.failed) }
        XCTAssertTrue(occupied.snapshot.contains { if case .error(let e) = $0 { e.code == .addressInUse } else { false } })
        await server.stop(); await server.stop(); try await server.start(config)
        try await sp.wait("restart") { sp.snapshot.filter { if case .stateChanged(.listening) = $0 { true } else { false } }.count == 2 }
        XCTAssertFalse(sp.hasState(.failed))
    }
    func testRejectsBroadcastMulticastOversizeAndUnreadySends() async throws {
        let service = UDPService(mode: .udpClient) { _ in }; services.append(service)
        do { _ = try await service.send(Data([1])); XCTFail("unready send") }
        catch { XCTAssertEqual((error as? NetDockError)?.code, .notReady) }
        for host in ["255.255.255.255", "224.0.0.1", "ff02::1"] {
            XCTAssertThrowsError(try SessionConfig(name: "invalid", mode: .udpClient, host: host, localPort: 0).validated())
        }
        let sp = DatagramProbe(); let server = try await start(SessionConfig(name: "server", mode: .udpServer, localPort: try port()), sp)
        do { _ = try await server.send(Data([1]), to: .allPeers); XCTFail("UDP must never expose TCP broadcast") } catch { }
        do { _ = try await server.send(Data(repeating: 1, count: 65_508), to: .endpoint(host: "127.0.0.1", port: 9)); XCTFail("oversize") }
        catch { XCTAssertEqual((error as? NetDockError)?.code, .datagramTooLarge) }
    }

    func testEmptyIncomingDatagramIsKeptAndReceptionContinues() async throws {
        let p = try port(); let probe = DatagramProbe()
        _ = try await start(SessionConfig(name: "empty receiver", mode: .udpServer, localPort: p), probe)
        let fd = socket(AF_INET, SOCK_DGRAM, 0); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = p.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sent = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, nil, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(sent, 0)
        try await probe.wait("empty datagram") { probe.received.count == 1 }
        XCTAssertEqual(probe.received[0].payload, Data())
        var byte: UInt8 = 255
        let next = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(next, 1)
        try await probe.wait("next datagram") { probe.received.count == 2 }
        XCTAssertEqual(probe.received[1].payload, Data([255]))
    }

    func testPeriodicRealUDPStopsAndTCPRemainsIndependent() async throws {
        let p = try port(); let probe = DatagramProbe(); let cp = DatagramProbe()
        let udp = try await start(SessionConfig(name: "UDP", mode: .udpServer, localPort: p), probe)
        let client = try await start(SessionConfig(name: "UDP client", mode: .udpClient, remotePort: p, localPort: 0), cp)
        let tcpStore = SessionTrafficStore(sessionID: UUID())
        let tcpServer = TCPService(mode: .tcpServer) { tcpStore.ingest($0) }
        try await tcpServer.start(SessionConfig(name: "TCP same port", mode: .tcpServer, localPort: p))
        let tcpClientStore = SessionTrafficStore(sessionID: UUID())
        let tcpClient = TCPService(mode: .tcpClient) { tcpClientStore.ingest($0) }
        try await tcpClient.start(SessionConfig(name: "TCP", remotePort: p))
        let sender = PeriodicSender()
        try sender.start(interval: 0.1, total: 3) { _ = try await client.send(Data([0, 255])) }
        await sender.waitUntilIdle()
        try await probe.wait("three timed datagrams") { probe.received.count == 3 }
        XCTAssertEqual(sender.sentCount, 3); XCTAssertEqual(sender.state, .completed)
        try sender.start(interval: 0.1, total: nil) { _ = try await client.send(Data([1])) }
        try await probe.wait("continuous started") { probe.received.count >= 4 }
        sender.stop(); await client.stop(); await sender.waitUntilIdle()
        let count = probe.received.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(probe.received.count, count)
        // Stopping UDP must not change the independent TCP listener/client.
        _ = try await tcpClient.send(Data([42]))
        var snapshot: TrafficSnapshot?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let next = tcpStore.takeSnapshot() { snapshot = next }
            if snapshot?.receivedBytes == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        XCTAssertEqual(snapshot?.receivedBytes, 1)
        await tcpClient.stop(); await tcpServer.stop(); await udp.stop()
    }
}
