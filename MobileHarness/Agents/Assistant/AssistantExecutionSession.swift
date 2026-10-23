import AgentCore
import Foundation
import Gateway
import PlatformKit
import StorageCore

/// Application-owned entry transport. Admission never waits for reasoning or child completion.
public actor AssistantExecutionSession {
    public nonisolated let agent: AssistantAgent
    private let manager: AgentManager
    private let output: OutputGateway
    private let startChildren: @Sendable () async throws -> Void
    private let report: @Sendable (String) async -> Void
    private var starting: Task<Void, Error>?
    private var pump: Task<Void, Never>?
    private var started = false
    private var closed = false

    public init(
        agent: AssistantAgent, manager: AgentManager, output: OutputGateway,
        startChildren: @escaping @Sendable () async throws -> Void,
        report: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.agent = agent
        self.manager = manager
        self.output = output
        self.startChildren = startChildren
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
            do {
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
                try await startChildren()
                guard !closed else { throw CommunicationError.scopeClosed }
                started = true
            } catch {
                try? await manager.remove(.assistant)
                pump?.cancel()
                await pump?.value
                pump = nil
                throw error
            }
        }
        starting = operation
        defer { starting = nil }
        try await operation.value
    }

    /// Registration is part of startup; scene changes must not look up children before it joins.
    public func setForeground(_ foreground: Bool) async throws {
        try await start()
        for descriptor in await manager.descriptors()
        where [AgentID.assistant, .photographer, .memory, .applicationControl].contains(descriptor.id) {
            let target = try await manager.agent(descriptor.id)
            let state = await target.status().lifecycle
            if foreground, state == .paused {
                try await target.resume()
            } else if !foreground, state == .running {
                try await target.pause()
            }
        }
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

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        starting?.cancel()
        _ = try? await starting?.value
        if started { try? await manager.remove(.assistant) }
        pump?.cancel()
        await pump?.value
        pump = nil
    }
}
