import Foundation

public struct SessionDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var sessions: [SessionConfig]
    public init(sessions: [SessionConfig] = []) { self.sessions = sessions }
}

public struct RepositoryLoad: Sendable {
    public let sessions: [SessionConfig]
    public let recoveredFromBackup: Bool
}

/// Call from a single owner. Writes atomically; preserves the last valid document as a backup.
public struct SessionRepository: Sendable {
    public let url: URL
    public var backupURL: URL { url.appendingPathExtension("backup") }
    public init(url: URL) { self.url = url }

    public func load() throws -> RepositoryLoad {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                return RepositoryLoad(sessions: try decode(Data(contentsOf: backupURL)), recoveredFromBackup: true)
            }
            return RepositoryLoad(sessions: [], recoveredFromBackup: false)
        }
        do { return RepositoryLoad(sessions: try decode(Data(contentsOf: url)), recoveredFromBackup: false) }
        catch {
            if let data = try? Data(contentsOf: backupURL), let sessions = try? decode(data) {
                return RepositoryLoad(sessions: sessions, recoveredFromBackup: true)
            }
            if let error = error as? NetDockError { throw error }
            throw NetDockError(.corruptStorage, detail: String(describing: error))
        }
    }

    public func save(_ sessions: [SessionConfig]) throws {
        do {
            try validate(sessions)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SessionDocument(sessions: sessions))
            if let existing = try? Data(contentsOf: url), (try? decode(existing)) != nil {
                try existing.write(to: backupURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                // Keep the damaged original for manual recovery before replacing it.
                try Data(contentsOf: url).write(to: url.appendingPathExtension("damaged"), options: .atomic)
            }
            try data.write(to: url, options: .atomic)
        } catch let error as NetDockError { throw error }
        catch { throw NetDockError(.storage, detail: String(describing: error)) }
    }

    private func decode(_ data: Data) throws -> [SessionConfig] {
        let document: SessionDocument
        do { document = try JSONDecoder().decode(SessionDocument.self, from: data) }
        catch { throw NetDockError(.corruptStorage, detail: String(describing: error)) }
        guard document.schemaVersion == 1 else { throw NetDockError(.schemaVersion) }
        try validate(document.sessions)
        return document.sessions
    }

    private func validate(_ sessions: [SessionConfig]) throws {
        guard Set(sessions.map(\.id)).count == sessions.count else { throw NetDockError(.corruptStorage) }
        for session in sessions { _ = try session.validated() }
    }
}
