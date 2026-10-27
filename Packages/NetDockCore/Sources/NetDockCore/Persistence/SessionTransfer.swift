import Foundation

/// Portable configuration only. Decoding never creates a connection or starts a session.
public enum SessionTransfer {
    public static let maximumBytes = 5 * 1_024 * 1_024
    public static let maximumSessions = 1_000

    public static func encode(_ sessions: [SessionConfig]) throws -> Data {
        let validated = try validate(sessions)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SessionDocument(sessions: validated))
        guard data.count <= maximumBytes else { throw NetDockError(.fileTooLarge) }
        return data
    }

    public static func decode(_ data: Data) throws -> [SessionConfig] {
        guard data.count <= maximumBytes else { throw NetDockError(.fileTooLarge) }
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(Version.self, from: data)
            guard version.schemaVersion == 1 else { throw NetDockError(.schemaVersion) }
            return try validate(decoder.decode(SessionDocument.self, from: data).sessions)
        } catch let error as NetDockError { throw error }
        catch { throw NetDockError(.corruptStorage, detail: String(describing: error)) }
    }

    private static func validate(_ sessions: [SessionConfig]) throws -> [SessionConfig] {
        guard sessions.count <= maximumSessions else { throw NetDockError(.fileTooLarge) }
        guard Set(sessions.map(\.id)).count == sessions.count else { throw NetDockError(.corruptStorage) }
        return try sessions.map { try $0.validated() }
    }

    private struct Version: Decodable { let schemaVersion: Int }
}
