import Foundation

public struct QuickCommand: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var encoding: DataEncoding
    public var payloadText: String
    public var sessionID: UUID?
    public var mode: SessionMode?

    public init(id: UUID = UUID(), title: String, encoding: DataEncoding, payloadText: String,
                sessionID: UUID? = nil, mode: SessionMode? = nil) {
        self.id = id; self.title = title; self.encoding = encoding; self.payloadText = payloadText
        self.sessionID = sessionID; self.mode = mode
    }

    public func validated() throws -> QuickCommand {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NetDockError(.invalidName) }
        _ = try PayloadCodec.encode(payloadText, as: encoding)
        return self
    }
}
