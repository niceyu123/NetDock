import Foundation

public enum ConnectionState: String, Codable, Sendable {
    case idle, starting, connecting, listening, ready, stopping, stopped, failed
    public var isActive: Bool { [.starting, .connecting, .listening, .ready, .stopping].contains(self) }
}

public struct NetDockError: Error, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidName, invalidHost, invalidPort, unsupportedMode, activeSession, emptyPayload, invalidHex, oddHex
        case notReady, noPeers, peerMissing, timeout, refused, addressInUse, permissionDenied
        case dns, network, storage, corruptStorage, schemaVersion, sendQueueFull
        case datagramTooLarge, unicastOnly, invalidInterval, invalidRepeatCount, fileTooLarge
    }
    public let code: Code
    public let detail: String
    public let position: Int?
    public init(_ code: Code, detail: String = "", position: Int? = nil) {
        self.code = code; self.detail = detail; self.position = position
    }
}
