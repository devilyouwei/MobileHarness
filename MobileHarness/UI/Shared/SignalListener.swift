import Foundation
import Synchronization

/// External Signal source (never routed through Gateway); UI owns this contract independently of PlatformKit and the business modules.
public protocol SignalListener<Element>: AsyncSequence, Sendable where Element: Sendable {
    var producer: String { get }
    func cancel() async
    func join() async
}

private final class UIListenerIteratorClaim: Sendable {
    private let claimed = Mutex(false)
    func take() -> Bool {
        claimed.withLock {
            if $0 { return false }
            $0 = true
            return true
        }
    }
}
private actor UIListenerDetachment {
    let operation: @Sendable () async -> Void
    var closing: Task<Void, Never>?
    init(_ operation: @escaping @Sendable () async -> Void) { self.operation = operation }
    func close() async {
        if let closing {
            await closing.value
            return
        }
        let task = Task { await operation() }
        closing = task
        await task.value
    }
}

/// Typed request/reply subscription; source-owned receipts retain accept/complete/cancellation.
public struct RequestSignalListener<Value: Sendable, Reply: Sendable>: SignalListener {
    public typealias Element = UIRequest<Value, Reply>
    public let producer: String
    public let capacity: Int
    private let stream: AsyncThrowingStream<Element, any Error>
    private let claim = UIListenerIteratorClaim()
    private let detachment: UIListenerDetachment
    init(
        producer: String, capacity: Int, stream: AsyncThrowingStream<Element, any Error>,
        detach: @escaping @Sendable () async -> Void
    ) {
        self.producer = producer
        self.capacity = capacity
        self.stream = stream
        detachment = UIListenerDetachment(detach)
    }
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = UIRequest<Value, Reply>
        private var base: AsyncThrowingStream<Element, any Error>.Iterator
        private let authorized: Bool
        fileprivate init(base: AsyncThrowingStream<Element, any Error>.Iterator, authorized: Bool) {
            self.base = base
            self.authorized = authorized
        }
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> Element? {
            guard authorized else { throw UIRequestError.duplicateConsumer }
            return try await base.next(isolation: actor)
        }
    }
    public func makeAsyncIterator() -> Iterator { .init(base: stream.makeAsyncIterator(), authorized: claim.take()) }
    public func cancel() async { await detachment.close() }
    /// Joins source detachment. The Agent owner separately joins admitted request processing.
    public func join() async { await detachment.close() }
}

/// UI-owned presentation facts. Latest-value replacement does not imply a business action completed.
public struct StateSignalListener<Value: Sendable>: SignalListener {
    public typealias Element = Value
    public let producer: String
    public let generation: UUID
    private let stream: AsyncStream<Value>
    private let claim = UIListenerIteratorClaim()
    private let detachment: UIListenerDetachment
    init(
        producer: String, generation: UUID, stream: AsyncStream<Value>,
        detach: @escaping @Sendable () async -> Void
    ) {
        self.producer = producer
        self.generation = generation
        self.stream = stream
        detachment = UIListenerDetachment(detach)
    }
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = Value
        private var base: AsyncStream<Value>.Iterator
        private let authorized: Bool
        fileprivate init(base: AsyncStream<Value>.Iterator, authorized: Bool) {
            self.base = base
            self.authorized = authorized
        }
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> Value? {
            guard authorized else { throw UIRequestError.duplicateConsumer }
            return await base.next(isolation: actor)
        }
    }
    public func makeAsyncIterator() -> Iterator { .init(base: stream.makeAsyncIterator(), authorized: claim.take()) }
    public func cancel() async { await detachment.close() }
    public func join() async { await detachment.close() }
}
