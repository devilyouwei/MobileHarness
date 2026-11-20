import Foundation
import Synchronization

/// External input identity and delivery policy; no Agent identity or business authority.
public struct SignalSource: Sendable, Equatable {
    public enum Delivery: Sendable, Equatable {
        case ordered(capacity: Int)
        case latest
    }
    public let producer: String
    public let generation: String
    public let delivery: Delivery
    public init(producer: String, generation: String, delivery: Delivery) {
        self.producer = producer
        self.generation = generation
        self.delivery = delivery
    }
}

/// External Signal source (never routed through Gateway). The consumer owns iteration and its processing task. join waits for source detachment only.
public protocol SignalListener<Element>: AsyncSequence, Sendable where Element: Sendable {
    var source: SignalSource { get }
    func cancel() async
    func join() async
}

public enum SignalListenerError: Error, Sendable { case duplicateConsumer, invalidMeasurement }
private final class ListenerIteratorClaim: Sendable {
    private let claimed = Mutex(false)
    func take() -> Bool {
        claimed.withLock {
            if $0 { return false }
            $0 = true
            return true
        }
    }
}

private actor SignalDetachment {
    private var task: Task<Void, Never>?
    private let detach: @Sendable () async -> Void
    init(_ detach: @escaping @Sendable () async -> Void) { self.detach = detach }
    func close() async {
        if let task {
            await task.value
            return
        }
        let task = Task { await detach() }
        self.task = task
        await task.value
    }
}

/// One native stream, with no additional buffer, copying or forwarding task.
public struct MediaSignalListener<Value: Sendable>: SignalListener {
    public typealias Element = Value
    public let source: SignalSource
    private let stream: AsyncThrowingStream<Value, any Error>
    private let claim = ListenerIteratorClaim()
    private let detachment: SignalDetachment
    public init(
        source: SignalSource, stream: AsyncThrowingStream<Value, any Error>,
        detach: @escaping @Sendable () async -> Void
    ) {
        self.source = source
        self.stream = stream
        detachment = SignalDetachment(detach)
    }
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = Value
        private var base: AsyncThrowingStream<Value, any Error>.Iterator
        private let authorized: Bool
        fileprivate init(base: AsyncThrowingStream<Value, any Error>.Iterator, authorized: Bool) {
            self.base = base
            self.authorized = authorized
        }
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> Value? {
            guard authorized else { throw SignalListenerError.duplicateConsumer }
            return try await base.next(isolation: actor)
        }
    }
    public func makeAsyncIterator() -> Iterator { .init(base: stream.makeAsyncIterator(), authorized: claim.take()) }
    public func cancel() async { await detachment.close() }
    public func join() async { await detachment.close() }
}

/// Snapshots and discrete native facts use the source's declared bounded policy.
public struct StateSignalListener<Value: Sendable>: SignalListener {
    public typealias Element = Value
    public let source: SignalSource
    private let media: MediaSignalListener<Value>
    public init(
        source: SignalSource, stream: AsyncThrowingStream<Value, any Error>,
        detach: @escaping @Sendable () async -> Void
    ) {
        self.source = source
        media = .init(source: source, stream: stream, detach: detach)
    }
    public func makeAsyncIterator() -> MediaSignalListener<Value>.Iterator { media.makeAsyncIterator() }
    public func cancel() async { await media.cancel() }
    public func join() async { await media.join() }
}

/// Missing or invalid sensor measurements are explicit; an unavailable reading is never a synthetic zero.
public struct SensorMeasurement<Value: Sendable>: Sendable {
    public enum Validity: Sendable, Equatable { case valid, unavailable, invalid }
    public let value: Value?
    public let unit: String
    public let sampledAt: ContinuousClock.Instant
    public struct Range: Sendable {
        public let lower: Value
        public let upper: Value
        public init(lower: Value, upper: Value) {
            self.lower = lower
            self.upper = upper
        }
    }
    public let validity: Validity
    public let range: Range?
    public let samplingFrequency: Double?
    public let calibrationID: String?
    public init(
        value: Value?, unit: String, sampledAt: ContinuousClock.Instant, validity: Validity,
        range: Range? = nil, samplingFrequency: Double? = nil, calibrationID: String? = nil
    ) throws {
        guard !unit.isEmpty, unit.utf8.count <= 64, validity != .valid || value != nil,
            samplingFrequency.map({ $0.isFinite && $0 > 0 }) ?? true,
            calibrationID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
        else { throw SignalListenerError.invalidMeasurement }
        self.range = range
        self.samplingFrequency = samplingFrequency
        self.calibrationID = calibrationID
        self.value = value
        self.unit = unit
        self.sampledAt = sampledAt
        self.validity = validity
    }
}

public struct SensorSignalListener<Value: Sendable>: SignalListener {
    public typealias Element = SensorMeasurement<Value>
    public var source: SignalSource { state.source }
    private let state: StateSignalListener<Element>
    public init(_ state: StateSignalListener<Element>) { self.state = state }
    public func makeAsyncIterator() -> MediaSignalListener<Element>.Iterator { state.makeAsyncIterator() }
    public func cancel() async { await state.cancel() }
    public func join() async { await state.join() }
}
