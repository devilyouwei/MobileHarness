import Foundation

/// Opaque correlation supplied by the host; no Agent, permissions or scheduling state.
public struct ToolExecutionContext: Sendable {
    public let source: String
    public let sessionID: UUID
    public let inputID: UUID
    public let sequence: UInt64
    public let correlationID: UUID?
    public let ordinal: UInt64?
    public init(
        source: String, sessionID: UUID, inputID: UUID, sequence: UInt64 = 0, correlationID: UUID? = nil,
        ordinal: UInt64? = nil
    ) {
        self.source = source
        self.sessionID = sessionID
        self.inputID = inputID
        self.sequence = sequence
        self.correlationID = correlationID
        self.ordinal = ordinal
    }
}
