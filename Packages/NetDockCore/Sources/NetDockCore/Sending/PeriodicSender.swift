import Foundation
import Observation

/// Serial periodic work. The caller captures a fixed target and payload in `operation`.
@MainActor @Observable
public final class PeriodicSender {
    public enum State: Equatable, Sendable { case idle, running, paused, completed }
    public private(set) var state: State = .idle
    public private(set) var sentCount = 0
    public private(set) var lastError: NetDockError?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskID: UUID?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var configuration: Configuration?

    public init() {}
    deinit { task?.cancel() }

    public func start(interval: TimeInterval, total: Int?, operation: @escaping @MainActor @Sendable () async throws -> Void) throws {
        guard interval.isFinite, interval >= 0.1 else { throw NetDockError(.invalidInterval) }
        guard total.map({ $0 > 0 }) ?? true else { throw NetDockError(.invalidRepeatCount) }
        task?.cancel()
        runID = UUID()
        configuration = Configuration(interval: interval, total: total, operation: operation)
        sentCount = 0; lastError = nil; state = .running
        launch()
    }

    public func pause() {
        guard state == .running else { return }
        state = .paused
        task?.cancel()
    }

    public func resume() {
        guard state == .paused, configuration != nil else { return }
        state = .running
        launch()
    }

    public func stop() {
        runID = UUID()
        configuration = nil
        state = .idle
        task?.cancel()
    }

    /// Waits for cancellation to reach any already-started operation, including replaced tasks.
    public func waitUntilIdle() async {
        while let pending = task {
            let pendingID = taskID
            await pending.value
            if pendingID == taskID { task = nil; taskID = nil }
        }
    }

    private func launch() {
        guard let configuration else { return }
        let previous = task
        let id = UUID(); let run = runID
        taskID = id
        task = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled, self?.canSend(run: run, id: id) == true {
                do {
                    try await configuration.operation()
                    self?.acceptSuccess(total: configuration.total, run: run)
                } catch {
                    self?.acceptFailure(error, run: run)
                    break
                }
                guard !Task.isCancelled, self?.canSend(run: run, id: id) == true else { break }
                do { try await Self.wait(interval: configuration.interval) }
                catch { break }
            }
            self?.finishTask(id: id)
        }
    }

    private func canSend(run: UUID, id: UUID) -> Bool {
        runID == run && taskID == id && state == .running
    }

    private func acceptSuccess(total: Int?, run: UUID) {
        guard runID == run else { return }
        // A paused operation already in flight may still finish successfully.
        sentCount += 1
        if let total, sentCount >= total { state = .completed; configuration = nil }
    }

    private func acceptFailure(_ error: any Error, run: UUID) {
        guard runID == run else { return }
        if error is CancellationError, Task.isCancelled { return }
        lastError = (error as? NetDockError) ?? NetDockError(.network, detail: String(describing: error))
        state = .idle; configuration = nil
        runID = UUID()
    }

    private func finishTask(id: UUID) {
        if taskID == id { task = nil; taskID = nil }
    }

    private static func wait(interval: TimeInterval) async throws {
        var remaining = interval
        while remaining > 0 {
            // Bound Duration conversion even for extremely large, finite user input.
            let chunk = min(remaining, 86_400)
            try await Task.sleep(for: .seconds(chunk))
            remaining -= chunk
        }
    }

    private struct Configuration {
        let interval: TimeInterval
        let total: Int?
        let operation: @MainActor @Sendable () async throws -> Void
    }
}
