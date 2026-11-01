import AgentCore
import Foundation
import Gateway
import Synchronization
import UI

/// Actor-owned subscription lifetimes. No business dispatch or application-owned consumer.
struct AgentUIInputs {
    @TaskLocal static var owner: AgentID?
    private var tasks: [Task<Void, Never>] = []
    private var close: [@Sendable () async -> Void] = []
    mutating func append(_ subscription: AgentUISubscription) {
        tasks.append(subscription.task)
        close.append(subscription.close)
    }
    mutating func retire(for owner: AgentID) -> @Sendable () async -> Void {
        for task in tasks { task.cancel() }
        let closing = close
        // A processing failure may stop its own Agent. Keep the tasks for the external owner's join.
        let retiring = Self.owner == owner ? [] : tasks
        if Self.owner != owner {
            tasks.removeAll()
            close.removeAll()
        }
        return {
            for operation in closing { await operation() }
            for task in retiring { await task.value }
        }
    }
}

struct AgentUISubscription: Sendable {
    let task: Task<Void, Never>
    let close: @Sendable () async -> Void
}

extension Agent {
    func consumeUI<Value: Sendable, Reply: Sendable>(
        _ requests: UIRequests<Value, Reply>, sessionID: String, maximumConcurrent: Int = 1,
        handle: @escaping @Sendable (isolated Self, Value, ProcessingContext) async throws -> Reply
    ) async throws -> AgentUISubscription {
        let stream = try await requests.listen()
        let controls: AsyncThrowingStream<UIRequest<Value, Reply>, any Error>
        do { controls = try await requests.listenControls() } catch {
            await requests.stopListening()
            throw error
        }
        let token = try await requests.listeningToken()
        let close: @Sendable () async -> Void = { await requests.stopListening(token: token) }
        let task = Task { [self] in
            await AgentUIInputs.$owner.withValue(descriptor.id) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await self.consumeUIStream(
                            stream, sessionID: sessionID, maximumConcurrent: maximumConcurrent, handle: handle)
                    }
                    group.addTask {
                        await self.consumeUIStream(controls, sessionID: sessionID, maximumConcurrent: 1, handle: handle)
                    }
                    await group.next()
                    group.cancelAll()
                }
                await close()
            }
        }
        return AgentUISubscription(task: task, close: close)
    }
    private func consumeUIStream<Value: Sendable, Reply: Sendable>(
        _ stream: AsyncThrowingStream<UIRequest<Value, Reply>, any Error>, sessionID: String, maximumConcurrent: Int,
        handle: @escaping @Sendable (isolated Self, Value, ProcessingContext) async throws -> Reply
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var count = 0
            do {
                for try await request in stream {
                    try Task.checkCancellation()
                    if count == max(1, min(4, maximumConcurrent)) {
                        await group.next()
                        count -= 1
                    }
                    group.addTask { await self.processUIRequest(request, sessionID: sessionID, handle: handle) }
                    count += 1
                }
            } catch {}
            group.cancelAll()
        }
    }
    private func processUIRequest<Value: Sendable, Reply: Sendable>(
        _ request: UIRequest<Value, Reply>, sessionID: String,
        handle: @escaping @Sendable (isolated Self, Value, ProcessingContext) async throws -> Reply
    ) async {
        guard !Task.isCancelled, await request.accept() else { return }
        let submitted = await request.submittedAt
        ContainerInputMetrics.record("UI.Admit", since: submitted)
        let context = await ProcessingContext(
            requestID: request.id.uuidString, sessionID: sessionID, generation: request.generation.uuidString)
        do {
            let value = await request.value
            let cancellation = AgentRequestCancellation()
            await request.onCancellation { cancellation.cancel() }
            let work = Task {
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
                return try await withUIRequestDeadline {
                    try await ProcessingContext.$current.withValue(context) { try await handle(self, value, context) }
                }
            }
            cancellation.install { work.cancel() }
            defer { cancellation.finish() }
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            ContainerInputMetrics.record("UI.Complete", since: submitted)
            await request.complete(.success(result))
        } catch {
            ContainerInputMetrics.record("UI.Fail", since: submitted)
            await request.complete(.failure(error))
        }
    }

}

/// Bounded output staging inside the owning Agent, not an input router or execution service.
/// UI fixed calls use the same identity-bound Gateway consumer as all other role outputs.
struct AgentUIExecution {
    var consumer: GatewayOutputConsumer?
    private var outputs: [String: [OutputEnvelope]] = [:]
    private var callIDs: [String: Set<String>] = [:]
    mutating func begin(_ id: String) throws -> GatewayOutputConsumer {
        guard let consumer else { throw UIRequestError.unavailable }
        guard outputs[id] == nil, outputs.count < 64 else { throw UIRequestError.capacityExceeded }
        outputs[id] = []
        callIDs[id] = []
        return consumer
    }
    mutating func capture(_ envelope: OutputEnvelope) throws -> Bool {
        guard outputs[envelope.inputID] != nil else { return false }
        guard (outputs[envelope.inputID]?.count ?? 0) < 64 else { throw UIRequestError.capacityExceeded }
        outputs[envelope.inputID]?.append(envelope)
        return true
    }
    mutating func next(_ id: String, maximumCalls: Int) throws -> OutputEnvelope? {
        guard outputs[id]?.isEmpty == false else { return nil }
        guard let envelope = outputs[id]?.removeFirst() else { return nil }
        if case .toolCall(let call) = envelope.output {
            guard (callIDs[id]?.count ?? 0) < maximumCalls,
                callIDs[id]?.insert(call.id).inserted == true
            else { throw CommunicationError.capacityExceeded }
        }
        return envelope
    }
    mutating func finish(_ id: String) {
        outputs[id] = nil
        callIDs[id] = nil
    }

}

func withUIRequestDeadline<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(120))
            throw CommunicationError.expired
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw CancellationError() }
        return value
    }
}

/// The actual request processing task is cancellable independently of its long-lived subscription.
private final class AgentRequestCancellation: Sendable {
    private struct State {
        var cancelled = false
        var cancel: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    func cancel() {
        let operation = state.withLock { value in
            value.cancelled = true
            let operation = value.cancel
            value.cancel = nil
            return operation
        }
        operation?()
    }
    func install(_ operation: @escaping @Sendable () -> Void) {
        let cancelled = state.withLock { value in
            guard !value.cancelled else { return true }
            value.cancel = operation
            return false
        }
        if cancelled { operation() }
    }
    func finish() { state.withLock { $0.cancel = nil } }
}
