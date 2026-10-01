import Foundation
import Synchronization

/// A conservative memory bound: capacity × maximum estimated bytes per event.
public struct StreamLimits: Equatable, Sendable {
    public let capacity: Int
    public let maximumEventBytes: Int

    public init(capacity: Int = 64, maximumEventBytes: Int = 4096) throws {
        guard capacity > 0, maximumEventBytes > 0,
            !capacity.multipliedReportingOverflow(by: maximumEventBytes).overflow
        else { throw CapabilityError.invalidRequest("Invalid stream limits") }
        self.capacity = capacity
        self.maximumEventBytes = maximumEventBytes
    }
}

public enum SessionTermination: Sendable {
    case finished
    case failed(any Error)
    case cancelled
}

/// Retain this handle while consuming events. Explicitly cancel when breaking out of a stream early.
public final class InferenceSession<Event: Sendable>: Sendable {
    public let context: InferenceContext
    public let events: InferenceEvents<Event>
    private let storage: SessionStorage<Event>

    private init(context: InferenceContext, storage: SessionStorage<Event>, stream: AsyncThrowingStream<Event, Error>) {
        self.context = context
        self.storage = storage
        events = InferenceEvents(storage: storage, stream: stream)
    }

    /// Adapter entry point. onTermination must be fast, nonblocking, and safe from any executor.
    public static func make(
        context: InferenceContext = InferenceContext(),
        limits: StreamLimits,
        estimatedBytes: @escaping @Sendable (Event) -> Int,
        onTermination: @escaping @Sendable (SessionTermination) -> Void = { _ in }
    ) -> (session: InferenceSession<Event>, emitter: InferenceEmitter<Event>) {
        let pair = AsyncThrowingStream<Event, Error>.makeStream(bufferingPolicy: .bufferingOldest(limits.capacity))
        let storage = SessionStorage(
            continuation: pair.continuation, capacity: limits.capacity, onTermination: onTermination)
        pair.continuation.onTermination = { termination in
            if case .cancelled = termination { storage.end(.cancelled) }
        }
        return (
            InferenceSession(context: context, storage: storage, stream: pair.stream),
            InferenceEmitter(
                storage: storage, maximumEventBytes: limits.maximumEventBytes, estimatedBytes: estimatedBytes)
        )
    }

    public func cancel() { storage.end(.cancelled) }
    func requireOpen() throws { _ = try storage.activeContinuation() }
    func fail(_ error: any Error) {
        if error is CancellationError { cancel() } else { storage.end(.failed(error)) }
    }
    deinit { storage.end(.cancelled) }
}

/// Single-consumer stream. Buffered events are not delivered after failure or cancellation.
public struct InferenceEvents<Event: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Event
    fileprivate let storage: SessionStorage<Event>
    fileprivate let stream: AsyncThrowingStream<Event, Error>

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var iterator: AsyncThrowingStream<Event, Error>.Iterator
        fileprivate let storage: SessionStorage<Event>
        fileprivate let accepted: Bool

        public mutating func next() async throws -> Event? {
            guard accepted else { throw CapabilityError.multipleConsumers }
            do {
                try Task.checkCancellation()
                try storage.checkFailure()
                let event = try await iterator.next()
                if event != nil { storage.consumed() }
                try Task.checkCancellation()
                try storage.checkFailure()
                return event
            } catch is CancellationError {
                storage.end(.cancelled)
                throw CancellationError()
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator(), storage: storage, accepted: storage.claimConsumer())
    }
}

/// Adapters serialize their emissions. Overflow fails the session instead of dropping output silently.
public struct InferenceEmitter<Event: Sendable>: Sendable {
    fileprivate let storage: SessionStorage<Event>
    fileprivate let maximumEventBytes: Int
    fileprivate let estimatedBytes: @Sendable (Event) -> Int

    public func yield(_ event: Event) throws {
        let bytes = estimatedBytes(event)
        guard bytes >= 0, bytes <= maximumEventBytes else {
            storage.end(.failed(CapabilityError.eventTooLarge))
            throw CapabilityError.eventTooLarge
        }
        let continuation = try storage.reserveEmission()
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped:
            storage.end(.failed(CapabilityError.bufferOverflow))
            throw CapabilityError.bufferOverflow
        case .terminated: throw CapabilityError.sessionClosed
        @unknown default:
            storage.end(.failed(CapabilityError.sessionClosed))
            throw CapabilityError.sessionClosed
        }
    }

    /// Serialized producers may suspend instead of failing on a full event buffer.
    public func yieldSuspending(_ event: Event) async throws {
        let bytes = estimatedBytes(event)
        guard bytes >= 0, bytes <= maximumEventBytes else {
            storage.end(.failed(CapabilityError.eventTooLarge))
            throw CapabilityError.eventTooLarge
        }
        try await storage.waitForCapacity()
        try Task.checkCancellation()
        try yield(event)
    }

    public func finish() { storage.end(.finished) }
    public func fail(_ error: any Error) { storage.end(.failed(error)) }
}

private final class SessionStorage<Event: Sendable>: Sendable {
    private struct State {
        var continuation: AsyncThrowingStream<Event, Error>.Continuation?
        var termination: SessionTermination?
        var consumerClaimed = false
        var outstanding = 0
        var capacityWaiter: CheckedContinuation<Void, Error>?
    }
    private let state: Mutex<State>
    private let capacity: Int
    private let onTermination: @Sendable (SessionTermination) -> Void

    init(
        continuation: AsyncThrowingStream<Event, Error>.Continuation, capacity: Int,
        onTermination: @escaping @Sendable (SessionTermination) -> Void
    ) {
        self.capacity = capacity
        state = Mutex(State(continuation: continuation))
        self.onTermination = onTermination
    }

    func claimConsumer() -> Bool {
        state.withLock {
            guard !$0.consumerClaimed else { return false }
            $0.consumerClaimed = true
            return true
        }
    }

    func activeContinuation() throws -> AsyncThrowingStream<Event, Error>.Continuation {
        try state.withLock {
            guard let continuation = $0.continuation else { throw CapabilityError.sessionClosed }
            return continuation
        }
    }

    func reserveEmission() throws -> AsyncThrowingStream<Event, Error>.Continuation {
        do {
            return try state.withLock { state in
                guard let continuation = state.continuation else { throw CapabilityError.sessionClosed }
                guard state.outstanding < capacity else { throw CapabilityError.bufferOverflow }
                state.outstanding += 1
                return continuation
            }
        } catch {
            end(.failed(error))
            throw error
        }
    }
    func consumed() {
        let waiter = state.withLock { state in
            state.outstanding = max(0, state.outstanding - 1)
            let waiter = state.capacityWaiter
            state.capacityWaiter = nil
            return waiter
        }
        waiter?.resume()
    }
    func waitForCapacity() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = state.withLock { state in
                    guard state.continuation != nil else { return .failure(CapabilityError.sessionClosed) }
                    if state.outstanding < capacity { return .success(()) }
                    guard state.capacityWaiter == nil else { return .failure(CapabilityError.bufferOverflow) }
                    state.capacityWaiter = waiter
                    return nil
                }
                if let result { waiter.resume(with: result) }
            }
        } onCancel: {
            self.end(.cancelled)
        }
    }

    func checkFailure() throws {
        try state.withLock {
            switch $0.termination {
            case .failed(let error): throw error
            case .cancelled: throw CancellationError()
            default: break
            }
        }
    }

    func end(_ termination: SessionTermination) {
        let continuation = state.withLock { state -> AsyncThrowingStream<Event, Error>.Continuation? in
            guard state.termination == nil else {
                // Cancellation also suppresses completed-but-not-yet-consumed buffered events.
                if case .finished = state.termination, case .cancelled = termination {
                    state.termination = .cancelled
                }
                return nil
            }
            state.termination = termination
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        let waiter = state.withLock { state in
            let waiter = state.capacityWaiter
            state.capacityWaiter = nil
            return waiter
        }
        waiter?.resume(throwing: CancellationError())
        guard let continuation else { return }
        // Never call a continuation or adapter callback while holding the mutex.
        switch termination {
        case .finished: continuation.finish()
        case .failed(let error): continuation.finish(throwing: error)
        case .cancelled: continuation.finish(throwing: CancellationError())
        }
        onTermination(termination)
    }
}
