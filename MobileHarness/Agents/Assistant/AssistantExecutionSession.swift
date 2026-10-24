import AgentCore
import Foundation
import Gateway
import PlatformKit
import StorageCore

/// Application-owned entry transport. Admission never waits for reasoning or child completion.
public actor AssistantExecutionSession {
    public nonisolated let agent: AssistantAgent
    public private(set) var cleanupFailure: AgentFailure?
    private var registeredForCleanup = false
    private let manager: AgentManager
    private let output: OutputGateway
    private let report: @Sendable (String) async -> Void
    private var starting: Task<Void, Error>?
    private var closing: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var started = false
    private var closed = false

    public init(
        agent: AssistantAgent, manager: AgentManager, output: OutputGateway,
        report: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.agent = agent
        self.manager = manager
        self.output = output
        self.report = report
    }

    public func start() async throws {
        guard !closed else { throw CommunicationError.scopeClosed }
        if started { return }
        if let starting {
            try await starting.value
            return
        }
        let operation = Task {
            try await manager.register(agent)
            registeredForCleanup = true
            do {
                try Task.checkCancellation()
                try await manager.start(.assistant)
                let consumer = try await output.consumer(for: agent)
                pump = Task {
                    do {
                        try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) { envelope in
                            do {
                                let outcome = try await consumer.execute(envelope)
                                if outcome.isError {
                                    await self.report(
                                        outcome.failure ?? outcome.tool?.value ?? "Agent execution failed")
                                }
                            } catch is CancellationError {
                                // Explicit host cancellation releases a playback seal without closing this reader.
                                try Task.checkCancellation()
                            } catch { await self.report("Agent output failed: \(error)") }
                        }
                    } catch is CancellationError {} catch { await report("Agent output transport stopped: \(error)") }
                }
                guard !closed else { throw CommunicationError.scopeClosed }
                started = true
            } catch {
                await removeRegistration()
                pump?.cancel()
                await pump?.value
                pump = nil
                if let cleanupFailure {
                    throw AgentFailure(
                        component: "assistant", operation: "start", underlying: error,
                        cleanupErrors: [cleanupFailure])
                }
                throw error
            }
        }
        starting = operation
        defer { starting = nil }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Only the Assistant is affected; peer lifecycle belongs to the module root.
    public func setForeground(_ foreground: Bool) async throws {
        try await start()
        let state = await agent.status().lifecycle
        if foreground, state == .paused { try await agent.resume() }
        if !foreground, state == .running { try await agent.pause() }
    }

    /// Stop accepted execution without ending the conversation or its public State scope.
    public func interruptConversation(sessionID: String) async throws {
        guard started, !closed else { return }
        async let calls: Void = output.cancelCalls(for: agent, sessionID: sessionID)
        async let model: Void = sendControl(.interruptSession, sessionID: sessionID)
        _ = try await (model, calls)
    }

    private func sendControl(_ control: AssistantSessionControl, sessionID: String) async throws {
        try await agent.receive(control.input(sessionID: sessionID))
    }

    private func removeRegistration() async {
        guard registeredForCleanup else { return }
        do {
            try await manager.remove(.assistant)
            registeredForCleanup = false
        } catch {
            cleanupFailure = AgentFailure(
                component: "assistant", operation: "stop",
                underlying: error, code: .cleanupFailed)
        }
    }
    public func shutdown() async {
        if let closing { return await closing.value }
        closed = true
        let task = Task {
            starting?.cancel()
            _ = await starting?.result
            await removeRegistration()
            pump?.cancel()
            await pump?.value
            pump = nil
        }
        closing = task
        await task.value
    }
}
