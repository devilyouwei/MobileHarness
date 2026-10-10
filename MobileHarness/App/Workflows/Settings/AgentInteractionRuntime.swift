import AgentCore
import Agents
import AppPresentationWorkflow
import Foundation
import Gateway

/// Application-owned entry transport. Admission never waits for reasoning or child completion.
public actor AgentInteractionRuntime {
    public nonisolated let agent: AssistantAgent
    private let manager: AgentManager
    private let input: InputGateway
    private let output: OutputGateway
    private let startChildren: @Sendable () async throws -> Void
    private let inputRejected: @Sendable (UUID, String) async -> Void
    private let report: @Sendable (String) async -> Void
    private var starting: Task<Void, Error>?
    private var pump: Task<Void, Never>?
    private var started = false
    private var closed = false
    private var textOrdinal: UInt64 = 0

    public init(
        agent: AssistantAgent, manager: AgentManager, input: InputGateway, output: OutputGateway,
        startChildren: @escaping @Sendable () async throws -> Void,
        report: @escaping @Sendable (String) async -> Void = { _ in },
        inputRejected: @escaping @Sendable (UUID, String) async -> Void = { _, _ in }
    ) {
        self.agent = agent
        self.manager = manager
        self.input = input
        self.output = output
        self.startChildren = startChildren
        self.report = report
        self.inputRejected = inputRejected
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
                                if case .control(let value) = envelope.output, value.hasPrefix("agent.inputRejected:") {
                                    await self.inputRejected(
                                        envelope.inputID, String(value.dropFirst("agent.inputRejected:".count)))
                                }
                                let outcome = try await consumer.execute(envelope)
                                if outcome.isError {
                                    await self.report(
                                        outcome.failure ?? outcome.tool?.value ?? "Agent execution failed")
                                }
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

    public func publish(_ signal: AgentInput) async throws {
        try await start()
        var signal = signal
        if case .text = signal.payload, signal.turn == nil {
            guard textOrdinal < UInt64.max else { throw CommunicationError.capacityExceeded }
            textOrdinal += 1
            signal = AgentInput(
                id: signal.id, sessionID: signal.sessionID, payload: signal.payload,
                metadata: signal.metadata, turn: AgentTurn(ordinal: textOrdinal), taskScope: signal.taskScope)
        }
        try await input.publish(signal)
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
