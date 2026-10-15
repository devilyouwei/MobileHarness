import Foundation

/// Opaque correlation supplied by the host; no Agent, permissions or scheduling state.
public struct ActionExecutionContext: Equatable, Sendable {
    public let source: String
    public let sessionID: String
    public let inputID: String
    public let sequence: UInt64
    public let correlationID: String?
    public let ordinal: UInt64?
    public let decisionID: String?
    public let taskID: String?
    public let taskExecutor: String?
    public init(
        source: String, sessionID: String, inputID: String, sequence: UInt64 = 0, correlationID: String? = nil,
        ordinal: UInt64? = nil, decisionID: String? = nil, taskID: String? = nil, taskExecutor: String? = nil
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
