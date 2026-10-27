import Foundation
import Network

public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case tcpClient, tcpServer, udpClient, udpServer

    public var isServer: Bool { self == .tcpServer || self == .udpServer }
    public var isImplemented: Bool { true }
    public var isUDP: Bool { self == .udpClient || self == .udpServer }
    public var title: String {
        switch self { case .tcpClient: "TCP Client"; case .tcpServer: "TCP Server"; case .udpClient: "UDP Client"; case .udpServer: "UDP Server" }
    }
    public func stateKey(_ state: ConnectionState) -> String {
        isUDP && state == .ready ? "udpReady" : "state.\(state.rawValue)"
    }
}

public enum DataEncoding: String, Codable, CaseIterable, Sendable {
    case utf8, hex
}

public struct SessionConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: SessionMode
    public var host: String
    public var remotePort: UInt16
    public var localPort: UInt16
    public var localHost: String
    public var sendEncoding: DataEncoding
    public var displayEncoding: DataEncoding
    public var autoScroll: Bool
    public var repeatInterval: TimeInterval
    public var repeatCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, mode: SessionMode = .tcpClient,
                host: String = "127.0.0.1", remotePort: UInt16 = 9000, localPort: UInt16 = 9000, localHost: String = "",
                sendEncoding: DataEncoding = .utf8, displayEncoding: DataEncoding = .utf8,
                autoScroll: Bool = true, repeatInterval: TimeInterval = 1, repeatCount: Int = 0,
                createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.name = name; self.mode = mode; self.host = host
        self.remotePort = remotePort; self.localPort = localPort
        self.localHost = localHost
        self.sendEncoding = sendEncoding; self.displayEncoding = displayEncoding
        self.autoScroll = autoScroll; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.repeatInterval = repeatInterval; self.repeatCount = repeatCount
    }

    public var endpointDescription: String {
        mode.isServer ? "\(localHost.isEmpty ? "*" : localHost.contains(":") ? "[\(localHost)]" : localHost):\(localPort)" : "\(host.contains(":") ? "[\(host)]" : host):\(remotePort)"
    }

    public func validated() throws -> SessionConfig {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NetDockError(.invalidName) }
        guard mode.isImplemented else { throw NetDockError(.unsupportedMode) }
        guard (mode.isServer ? localPort : remotePort) > 0 else { throw NetDockError(.invalidPort) }
        guard repeatInterval.isFinite, repeatInterval >= 0.1 else { throw NetDockError(.invalidInterval) }
        guard repeatCount >= 0 else { throw NetDockError(.invalidRepeatCount) }
        var result = self
        result.host = try EndpointInput.normalizedHost(host, required: !mode.isServer)
        result.localHost = try EndpointInput.normalizedHost(localHost, required: false)
        if mode.isUDP {
            if !mode.isServer { result.host = try EndpointInput.unicastHost(result.host) }
            if !result.localHost.isEmpty {
                guard IPv4Address(result.localHost) != nil || IPv6Address(result.localHost) != nil else { throw NetDockError(.invalidHost) }
            }
        }
        return result
    }

    /// Recheck at save time: another window may have started this session after editing began.
    public func validateUpdate(from current: SessionConfig, isActive: Bool) throws {
        guard isActive else { return }
        guard mode == current.mode else { throw NetDockError(.activeSession) }
        if mode.isUDP {
            guard localHost == current.localHost, localPort == current.localPort else { throw NetDockError(.activeSession) }
        }
        if mode.isServer {
            guard localPort == current.localPort else { throw NetDockError(.activeSession) }
        } else {
            guard try EndpointInput.normalizedHost(host) == EndpointInput.normalizedHost(current.host),
                  remotePort == current.remotePort else { throw NetDockError(.activeSession) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mode, host, remotePort, localPort, localHost, sendEncoding, displayEncoding, autoScroll, repeatInterval, repeatCount, createdAt, updatedAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        mode = try c.decode(SessionMode.self, forKey: .mode); host = try c.decode(String.self, forKey: .host)
        remotePort = try c.decode(UInt16.self, forKey: .remotePort); localPort = try c.decode(UInt16.self, forKey: .localPort)
        localHost = try c.decodeIfPresent(String.self, forKey: .localHost) ?? ""
        sendEncoding = try c.decode(DataEncoding.self, forKey: .sendEncoding)
        displayEncoding = try c.decode(DataEncoding.self, forKey: .displayEncoding)
        autoScroll = try c.decode(Bool.self, forKey: .autoScroll)
        repeatInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .repeatInterval) ?? 1
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public enum EndpointInput {
    public static func unicastHost(_ text: String) throws -> String {
        let host = try normalizedHost(text)
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes[0] > 0, bytes[0] < 224, bytes != [255, 255, 255, 255] else { throw NetDockError(.unicastOnly) }
        } else if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes[0] != 255, bytes.contains(where: { $0 != 0 }) else { throw NetDockError(.unicastOnly) }
            if bytes.prefix(12) == [0,0,0,0,0,0,0,0,0,0,255,255] {
                _ = try unicastHost(bytes.suffix(4).map(String.init).joined(separator: "."))
            }
        } else { throw NetDockError(.invalidHost) }
        return host
    }
    public static func port(_ text: String) throws -> UInt16 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(value), port > 0 else { throw NetDockError(.invalidPort) }
        return port
    }

    public static func normalizedHost(_ text: String, required: Bool = true) throws -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !required || (!host.isEmpty && !host.contains(where: { $0.isWhitespace }) &&
                            !host.contains("/") && !host.contains("[") && !host.contains("]")) else {
            throw NetDockError(.invalidHost)
        }
        return host
    }
}
