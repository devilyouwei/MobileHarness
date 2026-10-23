import Actions
import AgentCore
import Foundation
import Gateway
import UI

/// Role registration and protected output ownership; UI requests are consumed by the Agent.
public actor MemoryExecutionSession {
    public nonisolated let agent: MemoryAgent
    private let manager: AgentManager
    private let output: OutputGateway
    private var starting: Task<Void, Error>?
    private var pump: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var started = false
    private var registered = false
    private var closed = false
    public private(set) var lastExecutionFailure: String?

    public init(manager: AgentManager, output: OutputGateway, agent: MemoryAgent) {
        self.manager = manager
        self.output = output
        self.agent = agent
    }
    public func prepareForInteraction() async throws {
        guard !closed else { throw CommunicationError.scopeClosed }
        if started { return }
        if let starting { return try await starting.value }
        let operation = Task {
            try await manager.register(agent)
            registered = true
            do {
                let consumer = try await output.consumer(for: agent)
                await agent.bindUIExecution(consumer)
                try await manager.start(.memory)
                try Task.checkCancellation()
                guard !closed else { throw CommunicationError.scopeClosed }
                started = true
                pump = Task {
                    do {
                        try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) { envelope in
                            do { _ = try await consumer.execute(envelope) } catch {
                                await self.recordFailure(error)
                            }
                        }
                    } catch is CancellationError {} catch {
                        lastExecutionFailure = String(describing: error)
                    }
                    await closeResources()
                }
            } catch {
                let original = error
                do {
                    try await manager.remove(.memory)
                    registered = false
                } catch { throw NativeCleanupFailure(errors: [original, error]) }
                throw original
            }
        }
        starting = operation
        defer { starting = nil }
        try await operation.value
    }
    private func recordFailure(_ error: any Error) {
        lastExecutionFailure = String(String(describing: error).prefix(512))
    }
    public func shutdown() async {
        await closeResources()
        await pump?.value
        pump = nil
    }
    private func closeResources() async {
        if let closing { return await closing.value }
        closed = true
        let cleanup = Task {
            starting?.cancel()
            _ = await starting?.result
            if registered {
                do { try await manager.remove(.memory) } catch {
                    lastExecutionFailure = String(describing: error)
                }
                registered = false
            }
            pump?.cancel()
        }
        closing = cleanup
        await cleanup.value
    }
}
public enum HistoryIntentFailure: Error, Sendable {
    case execution(String)
}
