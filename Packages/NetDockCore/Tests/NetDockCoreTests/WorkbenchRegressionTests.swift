import XCTest
@testable import NetDockCore

@MainActor final class WorkbenchRegressionTests: XCTestCase {
    func testLargeBinaryNonmatchingSearchDoesNotFormatWholePayload() {
        let record = TrafficRecord(sessionID: UUID(), direction: .rx, payload: Data(repeating: 255, count: 4 * 1_024 * 1_024))
        let began = Date()
        XCTAssertFalse(TrafficQuery(search: "not-present-in-this-payload").matches(record))
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "Searching must not format megabytes of HEX")
        XCTAssertTrue(TrafficQuery(search: "FF\nFF").matches(record))
    }
    func testServerDurationCountsWhileSourcesAreConnectedAndFreezesAfterLastPeer() async throws {
        let store = SessionTrafficStore(sessionID: UUID(), mode: .tcpServer)
        store.ingest(.stateChanged(.listening))
        let peer = PeerInfo(id: UUID(), endpoint: "127.0.0.1:9", localEndpoint: nil, connectedAt: .now)
        store.ingest(.peerJoined(peer))
        try await Task.sleep(for: .milliseconds(30))
        store.ingest(.peerLeft(peer.id))
        let duration = try XCTUnwrap(store.takeSnapshot()).connectedDuration
        XCTAssertGreaterThan(duration, 0)
        try await Task.sleep(for: .milliseconds(30))
        store.ingest(.system("event.userStopped"))
        XCTAssertEqual(store.takeSnapshot()?.connectedDuration, duration)
    }
    func testTCPDoesNotClaimAnUnsupportedUDPBindAddressAfterModeConversion() throws {
        var config = SessionConfig(name: "UDP", mode: .udpServer, localHost: "::1")
        config.mode = .tcpServer
        let tcp = try config.validated()
        XCTAssertEqual(tcp.localHost, "")
        XCTAssertEqual(tcp.endpointDescription, "*:9000")
    }
}
