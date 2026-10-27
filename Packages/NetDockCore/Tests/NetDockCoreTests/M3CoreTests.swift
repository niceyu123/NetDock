import XCTest
@testable import NetDockCore

final class M3CoreTests: XCTestCase {
    func testQuickCommandValidatesTitleAndPayloadAndRoundTrips() throws {
        let command = QuickCommand(title: "校验", encoding: .hex, payloadText: "00 ff", sessionID: UUID(), mode: .udpClient)
        XCTAssertEqual(try command.validated(), command)
        XCTAssertEqual(try JSONDecoder().decode(QuickCommand.self, from: JSONEncoder().encode(command)), command)
        XCTAssertThrowsError(try QuickCommand(title: " \n", encoding: .utf8, payloadText: "hello").validated()) {
            XCTAssertEqual(($0 as? NetDockError)?.code, .invalidName)
        }
        XCTAssertThrowsError(try QuickCommand(title: "Invalid", encoding: .hex, payloadText: "GG").validated()) {
            XCTAssertEqual(($0 as? NetDockError)?.code, .invalidHex)
        }
        XCTAssertThrowsError(try QuickCommand(title: "Empty", encoding: .utf8, payloadText: "").validated())
    }

    func testCommandRepositoryRecoversLastValidBackupAndPreservesDamagedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CommandRepository(url: directory.appendingPathComponent("commands.json"))
        XCTAssertEqual(try repository.load(), [])
        let first = QuickCommand(title: "First", encoding: .hex, payloadText: "00 FF")
        try repository.save([first]); try repository.save([])
        XCTAssertEqual(try repository.load(), [])
        try Data("broken".utf8).write(to: repository.url)
        XCTAssertEqual(try repository.load(), [first])
        try repository.save([first])
        XCTAssertEqual(try Data(contentsOf: repository.url.appendingPathExtension("damaged")), Data("broken".utf8))
        try FileManager.default.removeItem(at: repository.url)
        XCTAssertEqual(try repository.load(), [first])
    }

    func testCommandRepositoryRejectsUnknownVersionDuplicateIDsAndLimits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CommandRepository(url: directory.appendingPathComponent("commands.json"))
        let command = QuickCommand(title: "One", encoding: .utf8, payloadText: "hello")
        try repository.save([command]); try repository.save([])
        try Data(#"{"schemaVersion":99,"commands":[]}"#.utf8).write(to: repository.url)
        XCTAssertThrowsError(try repository.load()) { XCTAssertEqual(($0 as? NetDockError)?.code, .schemaVersion) }
        XCTAssertThrowsError(try repository.save([command, command])) { XCTAssertEqual(($0 as? NetDockError)?.code, .corruptStorage) }
        let commands = (0..<1_001).map { QuickCommand(title: "\($0)", encoding: .utf8, payloadText: "x") }
        XCTAssertThrowsError(try repository.save(commands)) { XCTAssertEqual(($0 as? NetDockError)?.code, .fileTooLarge) }
        let huge = QuickCommand(title: "Huge", encoding: .utf8, payloadText: String(repeating: "x", count: 5 * 1_024 * 1_024))
        XCTAssertThrowsError(try repository.save([huge])) { XCTAssertEqual(($0 as? NetDockError)?.code, .fileTooLarge) }
        try Data(repeating: 32, count: 5 * 1_024 * 1_024 + 1).write(to: repository.url)
        try FileManager.default.removeItem(at: repository.backupURL)
        XCTAssertThrowsError(try repository.load()) { XCTAssertEqual(($0 as? NetDockError)?.code, .fileTooLarge) }
    }

    func testSessionTransferUsesRepositorySchemaAndValidatesBeforeReturning() throws {
        let sessions = [SessionConfig(name: "TCP", host: "[::1]"), SessionConfig(name: "UDP", mode: .udpServer, localPort: 9001)]
        let exported = try SessionTransfer.encode(sessions)
        let document = try JSONDecoder().decode(SessionDocument.self, from: exported)
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.sessions.map(\.id), sessions.map(\.id))
        let imported = try SessionTransfer.decode(exported)
        XCTAssertEqual(imported[0].host, "::1")
        XCTAssertEqual(imported.map(\.id), sessions.map(\.id))
        XCTAssertThrowsError(try SessionTransfer.decode(Data(#"{"schemaVersion":2,"sessions":[]}"#.utf8))) {
            XCTAssertEqual(($0 as? NetDockError)?.code, .schemaVersion)
        }
        XCTAssertThrowsError(try SessionTransfer.encode([sessions[0], sessions[0]]))
        XCTAssertThrowsError(try SessionTransfer.encode([SessionConfig(name: "Invalid", remotePort: 0)]))
        XCTAssertThrowsError(try SessionTransfer.decode(Data("garbage".utf8)))
        XCTAssertThrowsError(try SessionTransfer.decode(Data(repeating: 0, count: 5 * 1_024 * 1_024 + 1))) {
            XCTAssertEqual(($0 as? NetDockError)?.code, .fileTooLarge)
        }
        XCTAssertThrowsError(try SessionTransfer.encode((0..<1_001).map { SessionConfig(name: "\($0)") })) {
            XCTAssertEqual(($0 as? NetDockError)?.code, .fileTooLarge)
        }
    }

    func testTrafficJSONKeepsBinaryProtocolEndpointsAndSystemErrorIdentity() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let records = [
            TrafficRecord(sessionID: id, timestamp: timestamp, direction: .rx, payload: Data([0, 255]), remoteEndpoint: "[::1]:9", localEndpoint: "[::1]:10", protocolKind: .udp),
            TrafficRecord(sessionID: id, timestamp: timestamp, direction: .tx, payload: Data("你好".utf8)),
            TrafficRecord(sessionID: id, timestamp: timestamp, messageKey: "event.stopped", error: NetDockError(.network, detail: "closed", position: 7))
        ]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: TrafficExport.json(records)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let entries = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["payload"] as? String, "AP8=")
        XCTAssertEqual(entries[0]["protocol"] as? String, "UDP")
        XCTAssertEqual(entries[0]["direction"] as? String, "RX")
        XCTAssertEqual(entries[0]["size"] as? Int, 2)
        XCTAssertEqual(entries[0]["remoteEndpoint"] as? String, "[::1]:9")
        XCTAssertEqual(entries[0]["localEndpoint"] as? String, "[::1]:10")
        XCTAssertTrue((entries[0]["timestamp"] as? String)?.contains(".123") == true)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(entries[1]["payload"] as? String)), Data("你好".utf8))
        XCTAssertEqual(entries[2]["direction"] as? String, "SYS")
        XCTAssertEqual(entries[2]["kind"] as? String, "error")
        XCTAssertEqual(entries[2]["messageKey"] as? String, "event.stopped")
        let error = try XCTUnwrap(entries[2]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "network")
        XCTAssertEqual(error["detail"] as? String, "closed")
        XCTAssertEqual(error["position"] as? Int, 7)
    }

    func testTrafficTextShowsHexUTF8ValidityHighPrecisionAndSystemMessages() {
        let id = UUID()
        let records = [
            TrafficRecord(sessionID: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000.123456), direction: .rx, payload: Data([0, 255]), remoteEndpoint: "remote:9", localEndpoint: "local:10", protocolKind: .udp),
            TrafficRecord(sessionID: id, direction: .tx, payload: Data("你好".utf8)),
            TrafficRecord(sessionID: id, messageKey: "event.stopped", error: NetDockError(.network, detail: "closed"))
        ]
        let text = TrafficExport.text(records)
        for expected in [".123456", "remote:9", "local:10", "UDP", "RX", "00 FF", "invalid UTF-8", "TX", "你好", "SYS", "event.stopped", "network", "closed"] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected)")
        }
    }

    func testTrafficQueryFindsTextHexEndpointsDirectionAndErrorWithoutMixingFilters() {
        let id = UUID()
        let binary = TrafficRecord(sessionID: id, direction: .rx, payload: Data([0, 255]), remoteEndpoint: "Example.Local:9", protocolKind: .udp)
        let utf8 = TrafficRecord(sessionID: id, direction: .tx, payload: Data("Hello 世界".utf8))
        let system = TrafficRecord(sessionID: id, messageKey: "event.stopped", error: NetDockError(.permissionDenied, detail: "denied by user"))
        for query in ["00 ff", "example.local", "udp", "rx"] { XCTAssertTrue(TrafficQuery(search: query).matches(binary)) }
        XCTAssertTrue(TrafficQuery(search: "hELLo 世界", direction: .tx).matches(utf8))
        XCTAssertFalse(TrafficQuery(search: "hello", direction: .rx).matches(utf8))
        for query in ["sys", "permissiondenied", "denied by user", "event.stopped", "error"] {
            XCTAssertTrue(TrafficQuery(search: query).matches(system))
        }
        XCTAssertFalse(TrafficQuery(search: "missing").matches(binary))
        XCTAssertTrue(TrafficQuery(search: " \n").matches(binary))
    }
}
