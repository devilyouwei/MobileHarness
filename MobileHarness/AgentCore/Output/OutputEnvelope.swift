import Foundation

/// Source identity is attached by the runtime, never accepted from model output.
public struct OutputEnvelope: Sendable {
    public let source: AgentID
    public let inputID: UUID
    public let sessionID: UUID
    public let output: AgentOutput
    public init(source: AgentID, input: AgentInput, output: AgentOutput) {
        self.source = source
        self.inputID = input.id
        self.sessionID = input.sessionID
        self.output = output
    }
}
