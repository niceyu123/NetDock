import SwiftUI
import NetDockCore

@MainActor @Observable
final class AppModel {
    var sessions: [SessionConfig] = []
    var quickCommands: [QuickCommand] = []
    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var storageError: NetDockError?
    var recoveredStorage = false
    let sessionManager = SessionManager()
    private let defaults: UserDefaults
    private let repository: SessionRepository
    private let commandRepository: CommandRepository

    init(defaults: UserDefaults = .standard) {
        // UI automation uses its own local repository and preferences, never production sessions.
        let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let selectedDefaults = testing ? (UserDefaults(suiteName: "org.netdock.ui-testing") ?? defaults) : defaults
        if testing && ProcessInfo.processInfo.arguments.contains("-reset-ui-state") {
            selectedDefaults.removePersistentDomain(forName: "org.netdock.ui-testing")
        }
        self.defaults = selectedDefaults
        language = AppLanguage(rawValue: selectedDefaults.string(forKey: "language") ?? "") ?? .chinese
        appearance = AppearanceMode(rawValue: selectedDefaults.string(forKey: "appearance") ?? "") ?? .system
        let root = URL.applicationSupportDirectory.appendingPathComponent(testing ? "NetDock-UITests" : "NetDock", isDirectory: true)
        if testing && ProcessInfo.processInfo.arguments.contains("-reset-ui-state") {
            try? FileManager.default.removeItem(at: root)
        }
        repository = SessionRepository(url: root.appendingPathComponent("sessions.json"))
        commandRepository = CommandRepository(url: root.appendingPathComponent("commands.json"))
        do {
            let loaded = try repository.load()
            sessions = loaded.sessions; recoveredStorage = loaded.recoveredFromBackup
            sessionManager.synchronize(sessions)
        } catch { storageError = (error as? NetDockError) ?? NetDockError(.storage, detail: String(describing: error)) }
        do { quickCommands = try commandRepository.load() }
        catch { storageError = (error as? NetDockError) ?? NetDockError(.storage) }
    }

    @discardableResult func saveCommand(_ command: QuickCommand) -> Bool {
        do {
            let valid = try command.validated()
            var next = quickCommands
            if let index = next.firstIndex(where: { $0.id == valid.id }) { next[index] = valid } else { next.append(valid) }
            try commandRepository.save(next); quickCommands = next; return true
        } catch { storageError = (error as? NetDockError) ?? NetDockError(.storage); return false }
    }
    func deleteCommand(_ id: UUID) {
        do {
            let next = quickCommands.filter { $0.id != id }
            try commandRepository.save(next); quickCommands = next
        } catch { storageError = (error as? NetDockError) ?? NetDockError(.storage) }
    }
    @discardableResult func importSessions(_ data: Data) throws -> Int {
        var imported = try SessionTransfer.decode(data)
        for index in imported.indices { imported[index].id = UUID(); imported[index].createdAt = .now; imported[index].updatedAt = .now }
        let next = sessions + imported
        _ = try SessionTransfer.encode(next)
        try repository.save(next); sessions = next; sessionManager.synchronize(next)
        return imported.count
    }

    func t(_ key: String) -> String { L10n.text(key, language: language) }
    func errorText(_ error: NetDockError) -> String {
        var text = t("error.\(error.code.rawValue)")
        if let position = error.position { text += " · \(t("position")) \(position)" }
        if !error.detail.isEmpty { text += "\n\(error.detail)" }
        return text
    }

    @discardableResult func save(_ config: SessionConfig) -> Bool {
        do {
            var config = try config.validated(); config.updatedAt = .now
            if let runtime = sessionManager.runtimes[config.id] {
                try config.validateUpdate(from: runtime.config, isActive: runtime.isConfigurationLocked)
            }
            var next = sessions
            if let index = next.firstIndex(where: { $0.id == config.id }) { next[index] = config }
            else { next.append(config) }
            try repository.save(next); sessions = next; sessionManager.synchronize(next)
            return true
        } catch { storageError = (error as? NetDockError) ?? NetDockError(.storage); return false }
    }

    @discardableResult func saveEndpoint(_ runtime: SessionRuntime) -> Bool {
        guard !runtime.isConfigurationLocked else { return false }
        guard runtime.isEndpointDirty else { runtime.endpointError = nil; return true }
        do {
            var config = runtime.config
            let port = try EndpointInput.port(runtime.endpointPort)
            if config.mode.isServer { config.localPort = port }
            else { config.host = runtime.endpointHost; config.remotePort = port }
            let valid = try config.validated()
            guard save(valid) else {
                runtime.endpointError = storageError ?? NetDockError(.storage)
                storageError = nil
                return false
            }
            runtime.resetEndpointDraft()
            return true
        } catch {
            runtime.endpointError = (error as? NetDockError) ?? NetDockError(.invalidPort)
            return false
        }
    }

    @discardableResult func startSession(_ runtime: SessionRuntime) async -> Bool {
        guard saveEndpoint(runtime) else { return false }
        await runtime.start()
        return true
    }

    func delete(_ id: UUID) {
        do {
            let next = sessions.filter { $0.id != id }
            try repository.save(next); sessions = next; sessionManager.remove(id)
        } catch { storageError = (error as? NetDockError) ?? NetDockError(.storage) }
    }

    func duplicate(_ config: SessionConfig) {
        var copy = config; copy.id = UUID(); copy.name += " \(t("copy"))"; copy.createdAt = .now
        save(copy)
    }
}
