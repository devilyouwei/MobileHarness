import AgentCore
import Agents
import Foundation
import Gateway

/// One root-owned output consumer; camera and tracking workers cannot block each other's admission.
public actor PhotographerIntentRuntime {
    public nonisolated let agent: PhotographerAgent
    private let manager: AgentManager
    private let input: InputGateway
    private let output: OutputGateway
    private let sessionID: UUID
    private let report: @Sendable (String) async -> Void
    private var started = false
    private var closed = false
    private var pump: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var cancelAck: CheckedContinuation<Void, Never>?
    private var starting: Task<Void, Error>?
    private var trackingSession: UUID?
    private var trackingWorker: Task<Void, Never>?
    private var trackingQueue: [OutputEnvelope] = []
    private struct Request {
        let id: UUID
        let waiter: CheckedContinuation<Void, any Error>
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
                guard !closed else { throw CommunicationError.scopeClosed }
                started = true
                pump = Task.detached { [agent] in
                    for await envelope in agent.outputs {
                        if Task.isCancelled { break }
                        await self.consume(envelope)
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
    public func perform(
        _ operation: PhotographerCameraIntent.Operation,
        delegate: (@Sendable (AgentMessage) async throws -> DeliveryReport)? = nil
    ) async throws {
        guard operation != .cancel else { throw CommunicationError.unauthorized }
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        guard !closed else { throw CommunicationError.scopeClosed }
        guard request == nil else { throw CommunicationError.capacityExceeded }
        let intent = PhotographerCameraIntent(operation)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                request = Request(id: intent.requestID, waiter: waiter)
                request?.delivery = Task {
                    do {
                        let receipt: DeliveryReport
                        if let delegate {
                            receipt = try await delegate(intent.message)
                        } else {
                            receipt = try await input.send(intent.input(sessionID: sessionID), to: .photographer)
                        }
                        guard receipt.delivered == [.photographer], receipt.rejected.isEmpty else {
                            throw PhotographerIntentFailure.rejected(
                                receipt.failure ?? String(describing: receipt.rejected))
                        }
                    } catch { await cancel(intent.requestID, failure: error) }
                }
            }
        } onCancel: {
            Task { await self.cancel(intent.requestID, failure: CancellationError()) }
        }
    }
    private func consume(_ envelope: OutputEnvelope) async {
        guard envelope.source == .photographer else { return }
        if case .toolCall(let call) = envelope.output, call.toolPath.hasPrefix("Camera.Capture.") {
            guard !closed, request?.id == call.id, request?.worker == nil, request?.cancelling == false else {
                await report("Rejected unowned camera output")
                return
            }
            request?.inputID = envelope.inputID
            request?.sessionID = envelope.sessionID
            request?.worker = Task {
                do {
                    let result = try await output.execute(envelope)
                    await completed(call.id, outcome: result)
                } catch { await cancel(call.id, failure: error) }
            }
            return
        }
        if case .control("photographer.camera.cancelled") = envelope.output,
            request?.cancelling == true, request?.id == envelope.inputID, envelope.sessionID == sessionID
        {
            _ = try? await output.execute(envelope)
            request?.cancelAcknowledged = true
            cancelAck?.resume()
            cancelAck = nil
            return
        }
        if case .control(let state) = envelope.output, state.hasPrefix("photographer.camera.") {
            guard let active = request, !active.cancelling,
                active.inputID == envelope.inputID, active.sessionID == envelope.sessionID
            else { return }
            do {
                let result = try await output.execute(envelope)
                guard !result.isError else { throw PhotographerIntentFailure.execution(result) }
                request?.terminal = true
                finishIfReady()
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
                let result = try await output.execute(envelope)
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
            finishIfReady()
        }
    }
    private func finishIfReady() {
        guard let active = request, !active.cancelling, active.terminal, let result = active.outcome else { return }
        request = nil
        if result.isError {
            active.waiter.resume(throwing: PhotographerIntentFailure.execution(result))
        } else {
            active.waiter.resume()
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
            let receipt = try? await input.send(
                PhotographerCameraIntent(.cancel, requestID: id).input(sessionID: sessionID), to: .photographer)
            if receipt?.rejected.isEmpty != true {
                await report("Photographer cancellation Signal rejected")
            } else if request?.cancelAcknowledged == false {
                await withCheckedContinuation { cancelAck = $0 }
            }
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
        await agent.unbindTracking(sessionID: sessionID)
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
