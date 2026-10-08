import AgentCore
import Agents
import Foundation
import Gateway

/// Root-owned bounded transport. Agents select calls; this host only executes correlated outputs.
public actor HistoryIntentRuntime {
    public nonisolated let agent: MemoryAgent
    private let manager: AgentManager
    private let input: InputGateway
    private let output: OutputGateway
    private let sessionID: UUID
    private var started = false
    private var busy = false
    public init(
        sessionID: UUID, manager: AgentManager, input: InputGateway, output: OutputGateway,
        agent: MemoryAgent
    ) {
        self.sessionID = sessionID
        self.manager = manager
        self.input = input
        self.output = output
        self.agent = agent
    }
    public func startNew() async throws { try await run(.startNew) }
    public func summarize(_ id: UUID) async throws { try await run(.summarize(id)) }
    public func refresh() async throws { try await run(.refresh) }
    public func deleteArchived(_ id: UUID) async throws { try await run(.delete(id)) }
    private func run(_ intent: MemoryHistoryIntent) async throws {
        guard !busy else { throw CommunicationError.capacityExceeded }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        if !started {
            try await manager.register(agent, sessionID: sessionID)
            try await manager.start(.memory)
            started = true
        }
        try Task.checkCancellation()
        let request = intent.input(sessionID: sessionID)
        let receipt = try await input.send(request, to: .memory)
        guard receipt.rejected.isEmpty else {
            try Task.checkCancellation()
            throw CommunicationError.invalidPayload
        }
        do {
            // This is a bounded transport contract, not host-selected business behavior.
            let extended: Bool
            switch intent {
            case .startNew, .summarize: extended = true
            default: extended = false
            }
            let steps = extended ? 6 : (intent == .refresh ? 1 : 2)
            var handlerFailure: String?
            for _ in 0..<steps {
                guard let envelope = await read(request.id) else { throw CancellationError() }
                try Task.checkCancellation()
                let returning: Bool
                if case .toolCall(let call) = envelope.output {
                    returning = await output.returnsToolResult(for: call)
                } else {
                    returning = false
                }
                let result = try await output.execute(envelope)
                try Task.checkCancellation()
                if extended {
                    if let failure = result.failure { throw HistoryIntentFailure.execution(failure) }
                    if let tool = result.tool, tool.isError {
                        guard returning else { throw HistoryIntentFailure.execution(tool.value) }
                        handlerFailure = tool.value
                    }
                    if case .control("history.finished") = envelope.output { return }
                    if case .control("history.failed") = envelope.output {
                        throw HistoryIntentFailure.execution(handlerFailure ?? "History operation failed")
                    }
                } else if result.isError {
                    throw HistoryIntentFailure.execution(
                        result.failure ?? result.tool?.value ?? "History execution failed")
                }
            }
            if extended { throw HistoryIntentFailure.execution("History sequence exceeded output bound") }
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
        let cancellation = MemoryHistoryIntent.cancel(requestID).input(sessionID: sessionID)
        let receipt = try await input.send(cancellation, to: .memory)
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
