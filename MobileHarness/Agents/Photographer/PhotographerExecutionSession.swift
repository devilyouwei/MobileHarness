import AgentCore
import Foundation
import Gateway

/// Role-owned output pump and bounded tracking work. UI owns request receipts.
public actor PhotographerExecutionSession {
    public nonisolated let agent: PhotographerAgent
    public private(set) var cleanupFailure: AgentFailure?
    private var registeredForCleanup = false
    private let manager: AgentManager
    private let output: OutputGateway
    private var consumer: GatewayOutputConsumer?
    private let report: @Sendable (String) async -> Void
    private var started = false
    private var closed = false
    private var pump: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var starting: Task<Void, Error>?
    private var trackingSession: String?
    private var trackingWorker: Task<Void, Never>?
    /// Superseded intents are observable; they have never been submitted as device actions.
    public private(set) var supersededTrackingTargets: UInt64 = 0
    private var pendingTracking: OutputEnvelope?
    public init(
        manager: AgentManager, output: OutputGateway, agent: PhotographerAgent,
        report: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.manager = manager
        self.output = output
        self.agent = agent
        self.report = report
    }
    public func prepareForInteraction() async throws { try await prepare() }
    private func boundConsumer() throws -> GatewayOutputConsumer {
        guard let consumer else { throw CommunicationError.scopeClosed }
        return consumer
    }
    private func prepare() async throws {
        guard !closed else { throw CommunicationError.scopeClosed }
        if started { return }
        if let starting {
            try await starting.value
            return
        }
        let task = Task {
            try await manager.register(agent)
            registeredForCleanup = true
            do {
                try Task.checkCancellation()
                let bound = try await output.consumer(for: agent)
                consumer = bound
                await agent.bindUIExecution(bound)
                try await manager.start(.photographer)
                guard !closed else { throw CommunicationError.scopeClosed }
                started = true
                pump = Task.detached { [agent] in
                    do {
                        try await IndependentOutputWorkflow.consumeGeneration(agent.outputs) { envelope in
                            await self.consume(envelope)
                        }
                    } catch is CancellationError {} catch {
                        await self.report("Photographer output transport stopped: \(error)")
                    }
                }
            } catch {
                let original = error
                await removeRegistration()
                if let cleanupFailure {
                    throw AgentFailure(
                        component: "photographer", operation: "start",
                        underlying: original, cleanupErrors: [cleanupFailure])
                }
                throw original
            }
        }
        starting = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            starting = nil
            throw error
        }
        starting = nil
    }
    private func consume(_ envelope: OutputEnvelope) async {
        guard !closed, envelope.source == .photographer else { return }
        if envelope.roundID != nil || envelope.taskScope != nil
            || {
                if case .communication = envelope.output { return true }
                return false
            }()
        {
            do { _ = try await boundConsumer().execute(envelope) } catch {
                await report("Photographer output failed: \(error)")
            }
            return
        }
        guard envelope.sessionID == trackingSession else { return }
        if pendingTracking != nil, supersededTrackingTargets < .max {
            supersededTrackingTargets += 1
        }
        pendingTracking = envelope
        if trackingWorker == nil { trackingWorker = Task { await consumeTracking() } }
    }
    private func consumeTracking() async {
        defer { trackingWorker = nil }
        while !Task.isCancelled, let envelope = pendingTracking {
            pendingTracking = nil
            do {
                let result = try await boundConsumer().execute(envelope)
                if result.isError { await report(result.failure ?? result.tool?.value ?? "Tracking failed") }
            } catch is CancellationError { return } catch { await report(String(describing: error)) }
        }
    }
    public func attachTracking(sessionID: String) async throws {
        try await prepare()
        guard trackingSession == nil else { throw CommunicationError.capacityExceeded }
        try await agent.bindTracking(sessionID: sessionID)
        trackingSession = sessionID
    }
    public func detachTracking(sessionID: String) async {
        guard trackingSession == sessionID else { return }
        trackingSession = nil
        do { try await agent.unbindTracking(sessionID: sessionID) } catch { await report("保存追踪结束状态失败：\(error)") }
        pendingTracking = nil
        let worker = trackingWorker
        worker?.cancel()
        await worker?.value
        await output.cancel(sessionID: sessionID)
    }
    private func removeRegistration() async {
        guard registeredForCleanup else { return }
        do {
            await agent.finishPresentation()
            try await manager.remove(.photographer)
            registeredForCleanup = false
        } catch {
            cleanupFailure = AgentFailure(
                component: "photographer", operation: "stop",
                underlying: error, code: .cleanupFailed)
        }
    }
    public func shutdown() async {
        if let closing { return await closing.value }
        closed = true
        let task = Task {
            starting?.cancel()
            _ = await starting?.result
            if let session = trackingSession { await detachTracking(sessionID: session) }
            if registeredForCleanup { await removeRegistration() }
            pump?.cancel()
            await pump?.value
            pump = nil
        }
        closing = task
        await task.value
    }
}
public enum PhotographerIntentFailure: Error, Sendable, LocalizedError {
    case execution(OutputExecutionResult)
    public var errorDescription: String? {
        switch self {
        case .execution(let result):
            if case .report(let report)? = result.tool?.completion, let message = report.failureDescription {
                return String(message.prefix(512))
            }
            return String((result.failure ?? result.tool?.value ?? "Camera operation failed").prefix(512))
        }
    }
}
