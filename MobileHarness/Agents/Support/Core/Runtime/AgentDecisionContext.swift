import Foundation

/// Immutable execution selection. Media can be selected here without entering durable storage.
public struct AgentDecisionContext<State: AgentContextState>: Sendable {
    public let snapshot: AgentContext<State>
    public let input: AgentInput
    public init(snapshot: AgentContext<State>, input: AgentInput) {
        self.snapshot = snapshot
        self.input = input
    }
    public func batch() throws -> SignalBatch {
        try SignalBatch(
            taskID: input.taskScope?.id ?? input.id, signalIDs: [input.id],
            admissionSequence: snapshot.revision + 1)
    }
    public func selected(by batch: SignalBatch) throws -> AgentInput {
        guard batch.signalIDs == [input.id], batch.taskID == (input.taskScope?.id ?? input.id) else {
            throw CommunicationError.invalidPayload
        }
        return input
    }
}
