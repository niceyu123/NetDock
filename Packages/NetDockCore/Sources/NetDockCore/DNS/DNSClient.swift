import Foundation
import Network

public struct DNSLookup: Sendable {
    public let query: DNSQuery
    public let response: DNSMessage
    public let elapsed: TimeInterval
    public let usedTCP: Bool
}

public struct DNSClient: Sendable {
    public init() {}
    public func query(_ query: DNSQuery, timeout: TimeInterval = 5) async throws -> DNSLookup {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw NetDockError(.invalidInterval) }
        let request = DNSRequest(query: query, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start($0) }
        } onCancel: { request.cancel() }
    }
}

/// State, continuation and NWConnection callbacks are confined to one serial queue.
private final class DNSRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.netdock.dns", qos: .userInitiated)
    private let query: DNSQuery
    private let timeout: TimeInterval
    private let id = UInt16.random(in: .min ... .max)
    private let clock = ContinuousClock()
    private var started: ContinuousClock.Instant?
    private var continuation: CheckedContinuation<DNSLookup, any Error>?
    private var connection: NWConnection?
    private var deadline: DispatchWorkItem?
    private var generation = UUID()
    private var cancelled = false
    private var finished = false
    private var usingTCP = false
    private var tcpBytes = Data()

    init(query: DNSQuery, timeout: TimeInterval) { self.query = query; self.timeout = timeout }
    func start(_ continuation: CheckedContinuation<DNSLookup, any Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(CancellationError())); return }
            started = clock.now
            let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(NetDockError(.timeout))) }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
            connect(tcp: false)
        }
    }
    func cancel() {
        queue.async { [self] in
            cancelled = true
            if continuation != nil { finish(.failure(CancellationError())) }
        }
    }
    private func connect(tcp: Bool) {
        connection?.stateUpdateHandler = nil; connection?.cancel()
        generation = UUID(); let token = generation
        usingTCP = tcp; tcpBytes.removeAll(keepingCapacity: true)
        let connection = NWConnection(host: NWEndpoint.Host(query.server), port: NWEndpoint.Port(rawValue: query.port)!, using: tcp ? .tcp : .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, !self.finished, self.generation == token, let connection else { return }
            switch state {
            case .ready:
                var payload = DNSWire.encode(self.query, id: self.id)
                if tcp { payload = Data([UInt8(payload.count >> 8), UInt8(payload.count & 255)]) + payload }
                connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.finished, self.generation == token else { return }
                    if let error { self.finish(.failure(Self.describe(error))) }
                    else if tcp { self.receiveTCP(connection, token: token) }
                    else { self.receiveUDP(connection, token: token) }
                })
            case .failed(let error), .waiting(let error): self.finish(.failure(Self.describe(error)))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func receiveUDP(_ connection: NWConnection, token: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished, self.generation == token else { return }
            if let error { self.finish(.failure(Self.describe(error))); return }
            guard let data else { self.finish(.failure(NetDockError(.dnsMalformed))); return }
            do {
                let response = try DNSWire.decode(data, query: self.query, id: self.id)
                if response.truncated { self.connect(tcp: true) }
                else { self.succeed(response) }
            } catch let error as NetDockError where error.code == .dnsMismatch {
                // Ignore unrelated transactions; the original total deadline still applies.
                self.receiveUDP(connection, token: token)
            } catch { self.finish(.failure(error)) }
        }
    }
    private func receiveTCP(_ connection: NWConnection, token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_537 - tcpBytes.count) { [weak self] data, _, complete, error in
            guard let self, !self.finished, self.generation == token else { return }
            if let data { self.tcpBytes.append(data) }
            if self.tcpBytes.count >= 2 {
                let size = Int(self.tcpBytes[0]) << 8 | Int(self.tcpBytes[1])
                guard size >= 12 else { self.finish(.failure(NetDockError(.dnsMalformed))); return }
                if self.tcpBytes.count >= size + 2 {
                    do {
                        let response = try DNSWire.decode(Data(self.tcpBytes[2..<(size + 2)]), query: self.query, id: self.id)
                        guard !response.truncated else { throw NetDockError(.dnsMalformed) }
                        self.succeed(response)
                    } catch { self.finish(.failure(error)) }
                    return
                }
            }
            if let error { self.finish(.failure(Self.describe(error))) }
            else if complete { self.finish(.failure(NetDockError(.dnsMalformed))) }
            else { self.receiveTCP(connection, token: token) }
        }
    }
    private func succeed(_ response: DNSMessage) {
        let elapsed = started.map { $0.duration(to: clock.now) } ?? .zero
        let parts = elapsed.components
        finish(.success(DNSLookup(query: query, response: response,
                                  elapsed: Double(parts.seconds) + Double(parts.attoseconds) / 1e18, usedTCP: usingTCP)))
    }
    private func finish(_ result: Result<DNSLookup, any Error>) {
        guard !finished else { return }
        finished = true; generation = UUID()
        deadline?.cancel(); deadline = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        let continuation = continuation; self.continuation = nil
        continuation?.resume(with: result)
    }
    private static func describe(_ error: NWError) -> NetDockError {
        if case .posix(let code) = error, code == .EACCES || code == .EPERM { return NetDockError(.permissionDenied) }
        return NetDockError(.dns, detail: String(describing: error))
    }
}
