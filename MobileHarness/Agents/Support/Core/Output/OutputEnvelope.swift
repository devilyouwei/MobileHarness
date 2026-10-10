import Foundation

/// Source identity is attached by the runtime, never accepted from model output.
public struct OutputEnvelope: Sendable {
    public let source: AgentID
    public let inputMetadata: InputMetadata
    public let inputID: UUID
    public let sessionID: UUID
    public let turn: AgentTurn?
    public let taskScope: AgentTaskScope?
    public let sequence: UInt64
    public let roundID: UUID?
    public let callID: UUID?
    public var schedulingID: UUID { roundID ?? taskScope?.id ?? inputID }
    public let output: AgentOutput
    public init(
        source: AgentID, input: AgentInput, output: AgentOutput, sequence: UInt64 = 0, roundID: UUID? = nil,
        callID: UUID? = nil
    ) {
        self.roundID = roundID
        self.callID = callID
        self.inputMetadata = input.metadata
        self.turn = input.turn
        self.taskScope = input.taskScope
        self.sequence = sequence
        self.source = source
        self.inputID = input.id
        self.sessionID = input.sessionID
        self.output = output
    }
}
