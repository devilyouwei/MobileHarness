import ActionBindings
import AgentCore
import Agents
import Foundation
import Gateway
import PlatformKit
import Storage

/// Root-owned bounded transport. Agents select calls; this host only executes correlated outputs.
public actor HistoryIntentRuntime {
    public nonisolated let agent: MemoryAgent
    private let manager: AgentManager
    private let input: InputGateway
    private let output: OutputGateway
    private var consumer: GatewayOutputConsumer?
    private let sessionID: String
    private var closed = false
    private var started = false
    private var busy = false
    private var starting: Task<Void, Error>?
    private var pump: Task<Void, Never>?
    private var fixedOutputs: [OutputEnvelope] = []
    private var reader: CheckedContinuation<OutputEnvelope?, Never>?
    private var currentRequestID: String?
    private var inputFailure: String?
    public func rejectInput(_ id: String, reason: String) async {
        await agent.historyReads?.reject(id, sessionID: sessionID, error: HistoryIntentFailure.execution(reason))
        guard id == currentRequestID else { return }
        inputFailure = reason
        reader?.resume(returning: nil)
        reader = nil
    }

    public func prepareForInteraction() async throws {
        guard !closed else { throw CommunicationError.scopeClosed }
        if started { return }
        if let starting {
            try await starting.value
            return
        }
        let operation = Task {
            try await manager.register(agent)
            do {
                try await manager.start(.memory)
                consumer = try await output.consumer(for: agent)
                try Task.checkCancellation()
            } catch {
                try? await manager.remove(.memory)
                consumer = nil
                throw error
            }
            started = true
            pump = Task {
                do {
                    try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) { envelope in
                        await self.consume(envelope)
                    }
                } catch is CancellationError {} catch {
                    inputFailure = "History output transport failed: \(error)"
                    reader?.resume(returning: nil)
                    reader = nil
                }
            }
        }
        starting = operation
        defer { starting = nil }
        try await operation.value
    }
    private func consume(_ envelope: OutputEnvelope) async {
        if envelope.roundID != nil
            || {
                if case .communication = envelope.output { return true }
                return false
            }() || envelope.inputID != currentRequestID
        {
            do { _ = try await boundConsumer().execute(envelope) } catch {
                await rejectInput(envelope.inputID, reason: String(describing: error))
            }
            return
        }
        if let reader {
            self.reader = nil
            reader.resume(returning: envelope)
        } else if fixedOutputs.count < 8 {
            fixedOutputs.append(envelope)
        } else {
            inputFailure = "History output capacity exceeded"
            reader?.resume(returning: nil)
            reader = nil
        }
    }
    public init(
        sessionID: String, manager: AgentManager, input: InputGateway, output: OutputGateway,
        agent: MemoryAgent
    ) {
        self.sessionID = sessionID
        self.manager = manager
        self.input = input
        self.output = output
        self.agent = agent
    }
    public func shutdown() async {
        guard !closed else { return }
        closed = true
        starting?.cancel()
        _ = try? await starting?.value
        inputFailure = "History runtime stopped"
        reader?.resume(returning: nil)
        reader = nil
        if started { try? await manager.remove(.memory) }
        pump?.cancel()
        await pump?.value
        pump = nil
    }
    public func query(_ query: MemoryHistoryRead) async throws -> MemoryHistoryReadResult {
        try Task.checkCancellation()
        try await prepareForInteraction()
        try Task.checkCancellation()
        guard let reads = agent.historyReads else { throw CommunicationError.unavailableTarget }
        let id = try await reads.stage(query, sessionID: sessionID)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await reads.cancel(id, failure: CommunicationError.expired)
        }
        do {
            try await input.publish(MemoryHistoryIntent.query(id).input(sessionID: sessionID))
            let result = try await reads.value(id)
            watchdog.cancel()
            await watchdog.value
            return result
        } catch {
            watchdog.cancel()
            await watchdog.value
            await reads.discard(id)
            throw error
        }
    }
    public func startNew() async throws { try await run(.startNew) }
    public func summarize(_ id: String) async throws { try await run(.summarize(id)) }
    public func refresh() async throws { try await run(.refresh) }
    public func deleteArchived(_ id: String) async throws { try await run(.delete(id)) }
    private func boundConsumer() throws -> GatewayOutputConsumer {
        guard let consumer else { throw CommunicationError.scopeClosed }
        return consumer
    }
    private func run(_ intent: MemoryHistoryIntent) async throws {
        guard !busy else { throw CommunicationError.capacityExceeded }
        busy = true
        defer {
            busy = false
            currentRequestID = nil
            fixedOutputs.removeAll()
        }
        let request = try intent.input(sessionID: sessionID)
        currentRequestID = request.id
        inputFailure = nil
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await rejectInput(request.id, reason: "History result deadline exceeded")
        }
        do {
            try await runBody(intent, request: request)
            watchdog.cancel()
            await watchdog.value
        } catch {
            watchdog.cancel()
            await watchdog.value
            throw error
        }
    }
    private func runBody(_ intent: MemoryHistoryIntent, request: AgentInput) async throws {
        try Task.checkCancellation()
        try await prepareForInteraction()
        try Task.checkCancellation()
        defer {
            currentRequestID = nil
            fixedOutputs.removeAll()
        }
        try await input.publish(request)
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
                guard let envelope = await read(request.id) else {
                    throw HistoryIntentFailure.execution(inputFailure ?? "History stream closed")
                }
                try Task.checkCancellation()
                if case .control(let value) = envelope.output, value.hasPrefix("agent.error:") {
                    throw HistoryIntentFailure.execution(value)
                }
                let returning: Bool
                if case .toolCall(let call) = envelope.output {
                    returning = await output.returnsToolResult(for: call)
                } else {
                    returning = false
                }
                let result = try await boundConsumer().execute(envelope)
                try Task.checkCancellation()
                if extended {
                    if let failure = result.failure { throw HistoryIntentFailure.execution(failure) }
                    if let tool = result.tool, tool.isError {
                        guard returning else { throw HistoryIntentFailure.execution(tool.value) }
                        handlerFailure = tool.value
                    }
                    if case .control("history.finished") = envelope.output {
                        try await agent.completeFixedTask(inputID: request.id, value: "Completed")
                        return
                    }
                    if case .control("history.failed") = envelope.output {
                        throw HistoryIntentFailure.execution(handlerFailure ?? "History operation failed")
                    }
                } else if result.isError {
                    throw HistoryIntentFailure.execution(
                        result.failure ?? result.tool?.value ?? "History execution failed")
                }
            }
            if extended { throw HistoryIntentFailure.execution("History sequence exceeded output bound") }
            try await agent.completeFixedTask(inputID: request.id, value: "Completed")
        } catch {
            // The Tool has joined. Cleanup is independent of page cancellation and drains
            // any buffered follow-up before its acknowledgment, retaining admission until done.
            let cleanup = Task.detached { try await self.cancelAndDrain(request.id) }
            try await cleanup.value
            try await agent.completeFixedTask(inputID: request.id, value: nil, failure: String(describing: error))
            throw error
        }
    }
    private func read(_ requestID: String) async -> OutputEnvelope? {
        if !fixedOutputs.isEmpty { return fixedOutputs.removeFirst() }
        guard currentRequestID == requestID, reader == nil, inputFailure == nil else { return nil }
        return await withCheckedContinuation { reader = $0 }
    }
    private func cancelAndDrain(_ requestID: String) async throws {
        if inputFailure != nil { return }
        let cancellation = try MemoryHistoryIntent.cancel(requestID).input(sessionID: sessionID)
        try await input.publish(cancellation)
        // One active request, at most eight retained outputs. No device calls are admitted here.
        for _ in 0..<8 {
            guard let envelope = await read(requestID) else {
                throw HistoryIntentFailure.execution("History stream closed")
            }
            if case .control("history.cancelled") = envelope.output {
                let result = try await boundConsumer().execute(envelope)
                guard !result.isError else { throw HistoryIntentFailure.execution("History cleanup failed") }
                return
            }
            if case .control = envelope.output { _ = try await boundConsumer().execute(envelope) }
            // Cancelled presentation calls are intentionally retired without executing effects.
        }
        throw HistoryIntentFailure.execution("History cleanup exceeded output bound")
    }
}
public enum HistoryIntentFailure: Error, Sendable {
    case execution(String)
}
