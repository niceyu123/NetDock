import XCTest
@testable import NetDockCore

final class ModelTests: XCTestCase {
    func testUDPModesAcceptAutomaticClientPortAndPersistBinaryEncoding() throws {
        let client = SessionConfig(name: "UDP 中文", mode: .udpClient, host: "[::1]", localPort: 0,
                                   sendEncoding: .hex, displayEncoding: .hex)
        XCTAssertEqual(try client.validated().host, "::1")
        let server = SessionConfig(name: "UDP Server", mode: .udpServer, localPort: 9001)
        XCTAssertNoThrow(try server.validated())
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: JSONEncoder().encode(client))
        XCTAssertEqual(decoded, client)
    }

    func testActiveSessionRejectsEndpointAndModeEditsButAllowsDisplayPreferences() throws {
        let original = SessionConfig(name: "Client", host: "127.0.0.1", remotePort: 9000)
        var endpoint = original; endpoint.host = "::1"
        XCTAssertThrowsError(try endpoint.validateUpdate(from: original, isActive: true))
        endpoint = original; endpoint.remotePort = 9001
        XCTAssertThrowsError(try endpoint.validateUpdate(from: original, isActive: true))
        endpoint = original; endpoint.mode = .tcpServer
        XCTAssertThrowsError(try endpoint.validateUpdate(from: original, isActive: true))
        var preferences = original
        preferences.name = "Renamed"; preferences.sendEncoding = .hex
        preferences.displayEncoding = .hex; preferences.autoScroll = false
        XCTAssertNoThrow(try preferences.validateUpdate(from: original, isActive: true))
        XCTAssertNoThrow(try endpoint.validateUpdate(from: original, isActive: false))
        var server = SessionConfig(name: "Server", mode: .tcpServer, localPort: 9000)
        let previousServer = server; server.localPort = 9001
        XCTAssertThrowsError(try server.validateUpdate(from: previousServer, isActive: true))
    }

    func testEndpointValidation() throws {
        XCTAssertEqual(try EndpointInput.normalizedHost(" [::1] "), "::1")
        XCTAssertEqual(try EndpointInput.port("65535"), 65535)
        for value in ["0", "65536", "-1", "hello", "1.1", ""] {
            XCTAssertThrowsError(try EndpointInput.port(value))
        }
        XCTAssertThrowsError(try EndpointInput.normalizedHost("http://host"))
        XCTAssertThrowsError(try SessionConfig(name: " ").validated())
    }

    func testLegacySessionsDecodeAndActiveUDPBindingCannotChange() throws {
        let original = SessionConfig(name: "UDP", mode: .udpClient, localPort: 0)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "localHost"); json.removeValue(forKey: "repeatInterval"); json.removeValue(forKey: "repeatCount")
        XCTAssertEqual(try JSONDecoder().decode(SessionConfig.self, from: JSONSerialization.data(withJSONObject: json)).localHost, "")
        var changed = original; changed.localPort = 12345
        XCTAssertThrowsError(try changed.validateUpdate(from: original, isActive: true))
        changed = original; changed.localHost = "::1"
        XCTAssertThrowsError(try changed.validateUpdate(from: original, isActive: true))
    }

    func testRepositoryRoundTripAndBackupRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SessionRepository(url: directory.appendingPathComponent("sessions.json"))
        let session = SessionConfig(name: "测试", host: "::1")
        try repo.save([session]); try repo.save([])
        XCTAssertEqual(try repo.load().sessions, [])
        try Data("broken".utf8).write(to: repo.url)
        let result = try repo.load()
        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.sessions, [session])
        try repo.save(result.sessions)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url.appendingPathExtension("damaged").path))
    }

    func testRejectUnknownSchemaAndDuplicateIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SessionRepository(url: directory.appendingPathComponent("sessions.json"))
        try Data(#"{"schemaVersion":99,"sessions":[]}"#.utf8).write(to: repo.url)
        XCTAssertThrowsError(try repo.load()) { XCTAssertEqual(($0 as? NetDockError)?.code, .schemaVersion) }
        let session = SessionConfig(name: "Test")
        XCTAssertThrowsError(try repo.save([session, session]))
    }
}
