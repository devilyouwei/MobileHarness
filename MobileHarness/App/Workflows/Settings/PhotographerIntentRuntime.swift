import AgentCore
import Agents
import AppPresentationWorkflow
import Foundation
import Gateway

/// One root-owned output consumer; camera and tracking workers cannot block each other's admission.
public actor PhotographerIntentRuntime {
    public nonisolated let agent: PhotographerAgent
    private let manager: AgentManager
    private let input: InputGateway
    private let output: OutputGateway
    private var consumer: GatewayOutputConsumer?
    private let sessionID: UUID
    private let report: @Sendable (String) async -> Void

    public func prepareForInteraction() async throws { try await prepare() }
    private var started = false
    private var closed = false
    private var pump: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var starting: Task<Void, Error>?
    private var trackingSession: UUID?
    private var trackingWorker: Task<Void, Never>?
    private var trackingQueue: [OutputEnvelope] = []
    private struct Request {
        let id: UUID
        let waiter: CheckedContinuation<String?, any Error>
        var inputID: UUID?
        var sessionID: UUID?
        var delivery: Task<Void, Never>?
        var cancelAcknowledged = false
        var worker: Task<Void, Never>?
        var outcome: OutputExecutionResult?
        var terminal = false
        var cancelling = false
    }
    private var request: Request?
    public init(
        sessionID: UUID, manager: AgentManager, input: InputGateway, output: OutputGateway,
        agent: PhotographerAgent, report: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.manager = manager
        self.input = input
        self.output = output
        self.agent = agent
        self.report = report
    }
    public func rejectInput(_ id: UUID, reason: String) async {
        await cancel(id, failure: PhotographerIntentFailure.rejected(reason))
    }
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
            do {
                try await manager.start(.photographer)
                consumer = try await output.consumer(for: agent)
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
                try? await manager.remove(.photographer)
                throw error
            }
        }
        starting = task
        do { try await task.value } catch {
            starting = nil
            throw error
        }
        starting = nil
    }
    /// One-way passive observation; no command slot, model invocation or result waiter.
    public func observeCamera(_ value: CameraStateObservation) async throws {
        try value.validate()
        try await prepare()
        guard !closed else { throw CommunicationError.scopeClosed }
        try await input.publish(value.input(sessionID: sessionID))
    }

    @discardableResult public func perform(
        _ operation: PhotographerCameraIntent.Operation,
        facing: PhotographerCameraIntent.Facing? = nil, photoID: UUID? = nil
    ) async throws -> String? {
        guard operation != .cancel else { throw CommunicationError.unauthorized }
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        guard !closed else { throw CommunicationError.scopeClosed }
        guard request == nil else { throw CommunicationError.capacityExceeded }
        let intent = PhotographerCameraIntent(operation, facing: facing, photoID: photoID)
        _ = try intent.message.validatedSize()
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await cancel(
                intent.requestID, failure: PhotographerIntentFailure.rejected("Camera result deadline exceeded"))
        }
        do {
            let value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiter in
                    request = Request(id: intent.requestID, waiter: waiter)
                    request?.delivery = Task {
                        do {
                            try await input.publish(intent.input(sessionID: sessionID))

                        } catch { await cancel(intent.requestID, failure: error) }
                    }
                }
            } onCancel: {
                Task { await self.cancel(intent.requestID, failure: CancellationError()) }
            }
            watchdog.cancel()
            await watchdog.value
            return value
        } catch {
            watchdog.cancel()
            await watchdog.value
            throw error
        }
    }

    private func consume(_ envelope: OutputEnvelope) async {
        guard envelope.source == .photographer else { return }
        if envelope.roundID != nil
            || envelope.taskScope != nil && envelope.inputID != request?.inputID
                && envelope.inputMetadata.rootID != request?.id
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
        if case .control(let value) = envelope.output, value.hasPrefix("agent.error:"), let active = request,
            envelope.inputID == active.id
        {
            await cancel(active.id, failure: PhotographerIntentFailure.rejected(value))
            return
        }
        if case .toolCall(let call) = envelope.output, call.toolPath.hasPrefix("Camera.Capture.") {
            guard !closed, request?.id == call.id, request?.worker == nil, request?.cancelling == false else {
                await report("Rejected unowned camera output")
                return
            }
            request?.inputID = envelope.inputID
            request?.sessionID = envelope.sessionID
            request?.worker = Task {
                do {
                    let result = try await boundConsumer().execute(envelope)
                    await completed(call.id, outcome: result)
                } catch { await cancel(call.id, failure: error) }
            }
            return
        }
        if case .control("photographer.camera.cancelled") = envelope.output,
            request?.cancelling == true, request?.id == envelope.inputID, envelope.sessionID == sessionID
        {
            _ = try? await boundConsumer().execute(envelope)
            request?.cancelAcknowledged = true
            return
        }
        if case .control(let state) = envelope.output, state.hasPrefix("photographer.camera.") {
            guard let active = request, !active.cancelling,
                active.inputID == envelope.inputID, active.sessionID == envelope.sessionID
            else { return }
            do {
                let result = try await boundConsumer().execute(envelope)
                guard !result.isError else { throw PhotographerIntentFailure.execution(result) }
                request?.terminal = true
                await finishIfReady()
            } catch { await cancel(active.id, failure: error) }
            return
        }
        guard !closed, envelope.sessionID == trackingSession else { return }
        guard trackingQueue.count < 8 else {
            await report("Photographer tracking dispatch capacity exceeded")
            return
        }
        trackingQueue.append(envelope)
        if trackingWorker == nil { trackingWorker = Task { await consumeTracking() } }
    }
    private func consumeTracking() async {
        defer { trackingWorker = nil }
        while !Task.isCancelled, !trackingQueue.isEmpty {
            let envelope = trackingQueue.removeFirst()
            do {
                let result = try await boundConsumer().execute(envelope)
                if result.isError { await report(result.failure ?? result.tool?.value ?? "Tracking failed") }
            } catch is CancellationError { return } catch { await report(String(describing: error)) }
        }
    }
    private func completed(_ id: UUID, outcome: OutputExecutionResult) async {
        guard request?.id == id, request?.cancelling == false else { return }
        request?.outcome = outcome
        if outcome.failure != nil {
            await cancel(id, failure: PhotographerIntentFailure.execution(outcome))
        } else {
            await finishIfReady()
        }
    }
    private func finishIfReady() async {
        guard let active = request, !active.cancelling, active.terminal, let result = active.outcome else { return }
        do {
            try await agent.completeFixedTask(
                inputID: active.id, value: result.tool?.value,
                failure: result.isError ? result.failure ?? result.tool?.value ?? "Camera operation failed" : nil)
        } catch {
            request = nil
            active.waiter.resume(throwing: error)
            return
        }
        request = nil
        if result.isError {
            active.waiter.resume(throwing: PhotographerIntentFailure.execution(result))
        } else {
            active.waiter.resume(returning: result.tool?.value)
        }
    }
    private func cancel(_ id: UUID, failure: any Error) async {
        guard request?.id == id, request?.cancelling == false else { return }
        request?.cancelling = true
        let worker = request?.worker
        let delivery = request?.delivery
        worker?.cancel()
        delivery?.cancel()
        // Cleanup is separately owned so either delivery/worker may request cancellation without self-joining.
        cleanup = Task {
            await worker?.value
            await delivery?.value
            do {
                try await input.publish(PhotographerCameraIntent(.cancel, requestID: id).input(sessionID: sessionID))
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while request?.id == id, request?.cancelAcknowledged == false, ContinuousClock.now < deadline {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                }
                if request?.id == id, request?.cancelAcknowledged == false {
                    await report("Camera cancellation acknowledgment deadline exceeded")
                }
            } catch { await report("Photographer cancellation publication failed: \(error)") }
            guard let active = request, active.id == id else {
                cleanup = nil
                return
            }
            request = nil
            cleanup = nil
            active.waiter.resume(throwing: failure)
        }
    }
    public func attachTracking(sessionID: UUID) async throws {
        try await prepare()
        guard trackingSession == nil else { throw CommunicationError.capacityExceeded }
        try await agent.bindTracking(sessionID: sessionID)
        trackingSession = sessionID
    }
    public func detachTracking(sessionID: UUID) async {
        guard trackingSession == sessionID else { return }
        trackingSession = nil
        do { try await agent.unbindTracking(sessionID: sessionID) } catch { await report("保存追踪结束状态失败：\(error)") }
        trackingQueue.removeAll()
        let worker = trackingWorker
        worker?.cancel()
        await worker?.value
        await output.cancel(sessionID: sessionID)
    }
    public func shutdown() async {
        if let closing {
            await closing.value
            return
        }
        closed = true
        let task = Task { await close() }
        closing = task
        await task.value
    }
    private func close() async {
        await starting?.valueIgnoringFailure()
        if let session = trackingSession { await detachTracking(sessionID: session) }
        if let active = request { await cancel(active.id, failure: CancellationError()) }
        await cleanup?.value
        if started { try? await manager.remove(.photographer) }
        pump?.cancel()
        await pump?.value
        pump = nil
    }

}
public enum PhotographerIntentFailure: Error, Sendable, LocalizedError {
    case rejected(String)
    case execution(OutputExecutionResult)
    public var errorDescription: String? {
        switch self {
        case .rejected(let message): return String(message.prefix(512))
        case .execution(let result):
            if case .report(let report)? = result.tool?.completion, let message = report.failureDescription {
                return String(message.prefix(512))
            }
            return String((result.failure ?? result.tool?.value ?? "Camera operation failed").prefix(512))
        }
    }
}
extension Task where Success == Void, Failure == Error {
    fileprivate func valueIgnoringFailure() async { _ = try? await value }
}
