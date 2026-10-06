import AgentCore
import Agents
import Foundation
import Gateway

/// Root-owned bounded transport. Agents select calls; this host only executes correlated outputs.
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
    public func refresh() async throws { try await run(.refresh) }
    public func deleteArchived(_ id: UUID) async throws { try await run(.delete(id)) }
    private func run(_ intent: ConversationMemoryIntent) async throws {
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
        let request = intent.input(sessionID: sessionID)
        let receipt = try await input.send(request, to: .conversationMemory)
        guard receipt.rejected.isEmpty else {
            try Task.checkCancellation()
            throw CommunicationError.invalidPayload
        }
        do {
            // This is a bounded transport contract, not host-selected business behavior.
            let steps = if case .delete = intent { 2 } else { 1 }
            for _ in 0..<steps {
                guard let envelope = await read(request.id) else { throw CancellationError() }
                try Task.checkCancellation()
                let result = try await output.execute(envelope)
                try Task.checkCancellation()
                guard !result.isError else {
                    throw HistoryIntentFailure.execution(
                        result.failure ?? result.tool?.value ?? "History execution failed")
                }
            }
        } catch {
            // The Tool has joined. Cleanup is independent of page cancellation and drains
            // any buffered follow-up before its acknowledgment, retaining admission until done.
            let cleanup = Task.detached { try await self.cancelAndDrain(request.id) }
            try await cleanup.value
            throw error
        }
    }
    private func read(_ requestID: UUID) async -> OutputEnvelope? {
        let stream = agent.outputs
        let reader = Task.detached { () -> OutputEnvelope? in
            var iterator = stream.makeAsyncIterator()
            while let envelope = await iterator.next() {
                if envelope.inputID == requestID { return envelope }
            }
            return nil
        }
        return await reader.value
    }
    private func cancelAndDrain(_ requestID: UUID) async throws {
        let cancellation = ConversationMemoryIntent.cancel(requestID).input(sessionID: sessionID)
        let receipt = try await input.send(cancellation, to: .conversationMemory)
        guard receipt.rejected.isEmpty else { throw HistoryIntentFailure.execution("History cleanup rejected") }
        // One active request, at most eight retained outputs. No device calls are admitted here.
        for _ in 0..<8 {
            guard let envelope = await read(requestID) else {
                throw HistoryIntentFailure.execution("History stream closed")
            }
            if case .control("history.cancelled") = envelope.output {
                let result = try await output.execute(envelope)
                guard !result.isError else { throw HistoryIntentFailure.execution("History cleanup failed") }
                return
            }
            if case .control = envelope.output { _ = try await output.execute(envelope) }
            // Cancelled presentation calls are intentionally retired without executing effects.
        }
        throw HistoryIntentFailure.execution("History cleanup exceeded output bound")
    }
}
public enum HistoryIntentFailure: Error, Sendable {
    case execution(String)
}
