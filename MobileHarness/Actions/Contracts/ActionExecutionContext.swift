import Foundation

/// Opaque correlation supplied by the host; no Agent, permissions or scheduling state.
public struct ActionExecutionContext: Equatable, Sendable {
    public let source: String
    public let sessionID: UUID
    public let inputID: UUID
    public let sequence: UInt64
    public let correlationID: UUID?
    public let ordinal: UInt64?
    public let decisionID: UUID?
    public let taskID: UUID?
    public let taskExecutor: String?
    public init(
        source: String, sessionID: UUID, inputID: UUID, sequence: UInt64 = 0, correlationID: UUID? = nil,
        ordinal: UInt64? = nil, decisionID: UUID? = nil, taskID: UUID? = nil, taskExecutor: String? = nil
    ) {
        self.source = source
        self.sessionID = sessionID
        self.inputID = inputID
        self.sequence = sequence
        self.correlationID = correlationID
        self.ordinal = ordinal
        self.decisionID = decisionID
        self.taskID = taskID
        self.taskExecutor = taskExecutor
    }
}
