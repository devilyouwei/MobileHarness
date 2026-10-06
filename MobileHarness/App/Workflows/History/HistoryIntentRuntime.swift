import AgentCore
import Agents
import Foundation
import Gateway

/// Root-owned transport; one in-flight refresh, no backlog or model dependency.
public actor HistoryIntentRuntime {
    public nonisolated let agent: ConversationMemoryAgent
    private let manager: AgentManager
    private let input: InputGateway
    private let output: OutputGateway
    private let sessionID: UUID
    private var started = false
    private var busy = false
    public init(
        sessionID: UUID, manager: AgentManager, input: InputGateway, output: OutputGateway,
        agent: ConversationMemoryAgent
    ) {
        self.sessionID = sessionID
        self.manager = manager
        self.input = input
        self.output = output
        self.agent = agent
    }
    public func refresh() async throws {
        guard !busy else { throw CommunicationError.capacityExceeded }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        if !started {
            try await manager.register(agent, sessionID: sessionID)
            try await manager.start(.conversationMemory)
            started = true
        }
        try Task.checkCancellation()
        let request = ConversationMemoryIntent.refresh.input(sessionID: sessionID)
        let receipt = try await input.send(request, to: .conversationMemory)
        guard receipt.rejected.isEmpty else {
            try Task.checkCancellation()
            throw CommunicationError.invalidPayload
        }
        // The admitted Agent has already yielded its single output. An independent reader
        // joins that buffered result even when the page cancels, preserving the shared stream.
        let stream = agent.outputs
        let reader = Task.detached { () -> OutputEnvelope? in
            var iterator = stream.makeAsyncIterator()
            while let envelope = await iterator.next() {
                if envelope.inputID == request.id { return envelope }
                // Cancelled UI requests never execute their obsolete presentation.
            }
            return nil
        }
        guard let envelope = await reader.value else { throw CancellationError() }
        try Task.checkCancellation()
        let result = try await output.execute(envelope)
        try Task.checkCancellation()
        guard !result.isError else {
            throw HistoryIntentFailure.execution(result.failure ?? result.tool?.value ?? "History presentation failed")
        }
    }
}
public enum HistoryIntentFailure: Error, Sendable {
    case execution(String)
}
