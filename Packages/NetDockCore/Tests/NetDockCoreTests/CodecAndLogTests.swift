import XCTest
@testable import NetDockCore

final class CodecAndLogTests: XCTestCase {
    func testHexAcceptsWhitespaceCaseAndZeroBytes() throws {
        XCTAssertEqual(try PayloadCodec.encode("aA BB\n00\tff", as: .hex), Data([0xAA, 0xBB, 0, 0xFF]))
        XCTAssertEqual(PayloadCodec.hex(Data([0, 255, 16])), "00 FF 10")
    }
    func testHexRejectsEmptyOddAndInvalidWithPosition() {
        for text in ["", " \n\t"] {
            XCTAssertThrowsError(try PayloadCodec.encode(text, as: .hex)) { XCTAssertEqual(($0 as? NetDockError)?.code, .emptyPayload) }
        }
        XCTAssertThrowsError(try PayloadCodec.encode("AA B", as: .hex)) {
            XCTAssertEqual(($0 as? NetDockError), NetDockError(.oddHex, position: 4))
        }
        XCTAssertThrowsError(try PayloadCodec.encode("AA G0", as: .hex)) {
            XCTAssertEqual(($0 as? NetDockError), NetDockError(.invalidHex, position: 4))
        }
        XCTAssertThrowsError(try PayloadCodec.encode("ＦＦ", as: .hex))
    }
    func testUTF8RoundTripAndBinaryPreservation() throws {
        let bytes = try PayloadCodec.encode("网络工作台 🚢\u{0}", as: .utf8)
        XCTAssertEqual(PayloadCodec.text(bytes), "网络工作台 🚢\u{0}")
        let binary = Data([0xFF, 0, 0xC3])
        XCTAssertNil(PayloadCodec.text(binary))
        XCTAssertEqual(try PayloadCodec.encode(PayloadCodec.hex(binary), as: .hex), binary)
        XCTAssertThrowsError(try PayloadCodec.encode("", as: .utf8))
    }
    func testRingEvictsByCountAndByteLimit() {
        let session = UUID()
        var buffer = TrafficBuffer(maxEntries: 3, maxBytes: 5)
        for value: UInt8 in 0..<4 { buffer.append(TrafficRecord(sessionID: session, direction: .rx, payload: Data([value, value]))) }
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.payloadBytes, 4)
        XCTAssertEqual(buffer.records.map(\.payload), [Data([2, 2]), Data([3, 3])])
        buffer.removeAll()
        for _ in 0..<5 { buffer.append(TrafficRecord(sessionID: session, messageKey: "event.started")) }
        XCTAssertEqual(buffer.count, 3); XCTAssertEqual(buffer.payloadBytes, 0)
        buffer.append(TrafficRecord(sessionID: session, payload: Data(repeating: 1, count: 6)))
        XCTAssertEqual(buffer.count, 3)
        buffer.removeAll(); XCTAssertEqual(buffer.count, 0); XCTAssertEqual(buffer.payloadBytes, 0)
    }
    func testDefaultRingCapacityAndThirtyMiBGuard() {
        let session = UUID()
        var buffer = TrafficBuffer()
        for _ in 0..<5_001 { buffer.append(TrafficRecord(sessionID: session)) }
        XCTAssertEqual(buffer.count, 5_000)
        let oneMiB = Data(repeating: 7, count: 1_024 * 1_024)
        for _ in 0..<31 { buffer.append(TrafficRecord(sessionID: session, payload: oneMiB)) }
        XCTAssertEqual(buffer.count, 30)
        XCTAssertEqual(buffer.payloadBytes, 30 * 1_024 * 1_024)
    }
    func testTrafficStoreSeparatesSystemErrorsAndData() {
        let id = UUID(); let store = SessionTrafficStore(sessionID: id, maxEntries: 3)
        store.ingest(.system("event.started")); store.ingest(.stateChanged(.ready))
        store.ingest(.received(Transfer(timestamp: .now, payload: Data([0xFF]), peerID: nil, remoteEndpoint: "[::1]:9", localEndpoint: "[::1]:123")))
        store.ingest(.error(NetDockError(.network)))
        let snapshot = store.takeSnapshot()
        XCTAssertEqual(snapshot?.state, .ready)
        XCTAssertEqual(snapshot?.receivedBytes, 1); XCTAssertEqual(snapshot?.sentBytes, 0)
        XCTAssertEqual(snapshot?.records.map(\.direction), [.system, .rx, .system])
        XCTAssertEqual(snapshot?.records.map(\.kind), [.system, .data, .error])
        XCTAssertEqual(snapshot?.records[1].protocolKind, .tcp)
        XCTAssertEqual(snapshot?.records[1].payload, Data([0xFF]))
        XCTAssertNil(store.takeSnapshot())
        store.clear(); XCTAssertEqual(store.takeSnapshot()?.records.count, 0)
    }
}
