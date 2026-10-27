import Foundation

/// A single owner writes this repository. Raw traffic and send history are never saved here.
public struct CommandRepository: Sendable {
    public static let maximumCommands = 1_000
    public static let maximumBytes = 5 * 1_024 * 1_024
    public let url: URL
    public var backupURL: URL { url.appendingPathExtension("backup") }
    public init(url: URL) { self.url = url }

    public func load() throws -> [QuickCommand] {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { return [] }
            return try decode(read(backupURL))
        }
        do { return try decode(read(url)) }
        catch {
            // A future schema is not damaged storage. Do not silently roll it back.
            if let error = error as? NetDockError, error.code == .schemaVersion { throw error }
            if let backup = try? read(backupURL), let commands = try? decode(backup) { return commands }
            if let error = error as? NetDockError { throw error }
            throw NetDockError(.storage, detail: String(describing: error))
        }
    }

    public func save(_ commands: [QuickCommand]) throws {
        do {
            try validate(commands)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(commands: commands))
            guard data.count <= Self.maximumBytes else { throw NetDockError(.fileTooLarge) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try read(url)
                let destination: URL
                do {
                    _ = try decode(existing)
                    destination = backupURL
                } catch let error as NetDockError where error.code == .schemaVersion {
                    throw error
                } catch {
                    destination = url.appendingPathExtension("damaged")
                }
                try existing.write(to: destination, options: .atomic)
            }
            try data.write(to: url, options: .atomic)
        } catch let error as NetDockError { throw error }
        catch { throw NetDockError(.storage, detail: String(describing: error)) }
    }

    private func read(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 * 1_024, Self.maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maximumBytes else { throw NetDockError(.fileTooLarge) }
        }
        return data
    }

    private func decode(_ data: Data) throws -> [QuickCommand] {
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(Version.self, from: data)
            guard version.schemaVersion == 1 else { throw NetDockError(.schemaVersion) }
            let commands = try decoder.decode(Document.self, from: data).commands
            try validate(commands)
            return commands
        } catch let error as NetDockError { throw error }
        catch { throw NetDockError(.corruptStorage, detail: String(describing: error)) }
    }

    private func validate(_ commands: [QuickCommand]) throws {
        guard commands.count <= Self.maximumCommands else { throw NetDockError(.fileTooLarge) }
        guard Set(commands.map(\.id)).count == commands.count else { throw NetDockError(.corruptStorage) }
        for command in commands { _ = try command.validated() }
    }

    private struct Version: Decodable { let schemaVersion: Int }
    private struct Document: Codable {
        var schemaVersion = 1
        let commands: [QuickCommand]
    }
}
