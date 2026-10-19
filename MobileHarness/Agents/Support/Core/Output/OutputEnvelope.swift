import Foundation

/// Source identity is attached by the runtime, never accepted from model output.
public struct OutputEnvelope: Sendable {
    public let source: AgentID
    public let inputMetadata: InputMetadata
    public let inputID: String
    public let sessionID: String
    public let turn: AgentTurn?
    public let taskScope: AgentTaskScope?
    public let sequence: UInt64
    public let roundID: String?
    public let callID: String?
    public var schedulingID: String { roundID ?? taskScope?.id ?? inputID }
    public let output: AgentOutput
    public let media: ImageInput?
    public let failure: AgentFailureDiagnostic?
    public init(
        source: AgentID, input: AgentInput, output: AgentOutput, sequence: UInt64 = 0, roundID: String? = nil,
        callID: String? = nil, failure: AgentFailureDiagnostic? = nil, media: ImageInput? = nil
    ) {
        if failure != nil {
            guard case .control(let value) = output, value.hasPrefix("agent.error:") else {
                preconditionFailure("Failure diagnostics require an Agent error control")
            }
        }
        self.media = media
        self.failure = failure
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
