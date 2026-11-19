import Foundation
import ModelKit
import Synchronization
import Testing

private final class EndCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

@Test func unboundedEventsRetainWholeGenerationBeforeConsumerStarts() async throws {
    let pair = InferenceSession<Int>.make(
        limits: try StreamLimits(capacity: nil), estimatedBytes: { _ in 8 })
    for value in 0..<20000 { try pair.emitter.yield(value) }
    try await pair.emitter.yieldSuspending(20000)
    pair.emitter.finish()
    var received: [Int] = []
    for try await event in pair.session.events { received.append(event) }
    #expect(received == Array(0...20000))
}

@Test func unboundedEventsStillValidateSizeAndCancellation() async throws {
    let oversized = InferenceSession<String>.make(
        limits: try StreamLimits(capacity: nil, maximumEventBytes: 2), estimatedBytes: { $0.utf8.count })
    #expect(throws: CapabilityError.eventTooLarge) { try oversized.emitter.yield("你") }
    let pair = InferenceSession<Int>.make(
        limits: try StreamLimits(capacity: nil), estimatedBytes: { _ in 8 })
    for value in 0..<1000 { try pair.emitter.yield(value) }
    pair.emitter.finish()
    pair.session.cancel()
    var iterator = pair.session.events.makeAsyncIterator()
    await #expect(throws: CancellationError.self) { try await iterator.next() }
    #expect(throws: CapabilityError.sessionClosed) { try pair.emitter.yield(1000) }
    #expect(throws: CapabilityError.self) { try StreamLimits(capacity: nil, maximumEventBytes: 0) }
}

@Test func orderedEventsDrainOnNormalFinish() async throws {
    let pair = InferenceSession<String>.make(limits: try StreamLimits(capacity: 2), estimatedBytes: { $0.utf8.count })
    try pair.emitter.yield("一")
    try pair.emitter.yield("二")
    pair.emitter.finish()
    var received: [String] = []
    for try await event in pair.session.events { received.append(event) }
    #expect(received == ["一", "二"])
    #expect(throws: CapabilityError.sessionClosed) { try pair.emitter.yield("三") }
}

@Test func overflowIsAnErrorAndDiscardsBufferedOutput() async throws {
    let counter = EndCounter()
    let pair = InferenceSession<String>.make(
        limits: try StreamLimits(capacity: 1), estimatedBytes: { $0.utf8.count },
        onTermination: { _ in counter.increment() })
    try pair.emitter.yield("first")
    #expect(throws: CapabilityError.bufferOverflow) { try pair.emitter.yield("second") }
    var iterator = pair.session.events.makeAsyncIterator()
    await #expect(throws: CapabilityError.bufferOverflow) { _ = try await iterator.next() }
    pair.session.cancel()
    pair.emitter.finish()
    #expect(counter.count == 1)
}

@Test func byteLimitRejectsOversizedUnicodeEvent() async throws {
    let pair = InferenceSession<String>.make(
        limits: try StreamLimits(maximumEventBytes: 2), estimatedBytes: { $0.utf8.count })
    #expect(throws: CapabilityError.eventTooLarge) { try pair.emitter.yield("你") }
    var iterator = pair.session.events.makeAsyncIterator()
    await #expect(throws: CapabilityError.eventTooLarge) { _ = try await iterator.next() }
}

@Test func cancellationIsPerSessionAndIdempotent() async throws {
    let counter = EndCounter()
    let first = InferenceSession<String>.make(
        limits: try StreamLimits(), estimatedBytes: { $0.utf8.count },
        onTermination: { _ in counter.increment() })
    let second = InferenceSession<String>.make(limits: try StreamLimits(), estimatedBytes: { $0.utf8.count })
    try first.emitter.yield("pending")
    first.session.cancel()
    first.session.cancel()
    var iterator = first.session.events.makeAsyncIterator()
    await #expect(throws: CancellationError.self) { _ = try await iterator.next() }
    #expect(throws: CapabilityError.sessionClosed) { try first.emitter.yield("late") }
    try second.emitter.yield("unaffected")
    second.emitter.finish()
    var secondIterator = second.session.events.makeAsyncIterator()
    #expect(try await secondIterator.next() == "unaffected")
    #expect(counter.count == 1)
}

@Test func cancelAfterProducerFinishDiscardsQueuedEvents() async throws {
    let pair = InferenceSession<String>.make(limits: try StreamLimits(), estimatedBytes: { $0.utf8.count })
    try pair.emitter.yield("pending")
    pair.emitter.finish()
    pair.session.cancel()
    var iterator = pair.session.events.makeAsyncIterator()
    await #expect(throws: CancellationError.self) { _ = try await iterator.next() }
}

@Test func consumerTaskCancellationClosesSession() async throws {
    let counter = EndCounter()
    let pair = InferenceSession<String>.make(
        limits: try StreamLimits(), estimatedBytes: { $0.utf8.count },
        onTermination: { _ in counter.increment() })
    let consumer = Task {
        var iterator = pair.session.events.makeAsyncIterator()
        return try await iterator.next()
    }
    consumer.cancel()
    await #expect(throws: CancellationError.self) { _ = try await consumer.value }
    #expect(counter.count == 1)
}

@Test func secondConsumerIsRejected() async throws {
    let pair = InferenceSession<Int>.make(limits: try StreamLimits(), estimatedBytes: { _ in 8 })
    var first = pair.session.events.makeAsyncIterator()
    var second = pair.session.events.makeAsyncIterator()
    await #expect(throws: CapabilityError.multipleConsumers) { _ = try await second.next() }
    try pair.emitter.yield(1)
    pair.emitter.finish()
    #expect(try await first.next() == 1)
}

@Test func droppingHandleTerminatesProducer() throws {
    let counter = EndCounter()
    var handle: InferenceSession<Int>?
    var emitter: InferenceEmitter<Int>?
    do {
        let pair = InferenceSession<Int>.make(
            limits: try StreamLimits(), estimatedBytes: { _ in 8 },
            onTermination: { _ in counter.increment() })
        handle = pair.session
        emitter = pair.emitter
    }
    #expect(handle != nil)
    handle = nil
    #expect(counter.count == 1)
    #expect(throws: CapabilityError.sessionClosed) { try emitter?.yield(1) }
}

@Test(.timeLimit(.minutes(1))) func suspendingEmissionBackpressuresAndDrainsInOrder() async throws {
    let pair = InferenceSession<Int>.make(limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 8 })
    let producer = Task {
        for value in 0..<100 { try await pair.emitter.yieldSuspending(value) }
        pair.emitter.finish()
    }
    var values: [Int] = []
    for try await value in pair.session.events { values.append(value) }
    try await producer.value
    #expect(values == Array(0..<100))
}

@Test(.timeLimit(.minutes(1))) func sessionCancellationUnblocksSuspendedEmitter() async throws {
    let pair = InferenceSession<Int>.make(limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 8 })
    try pair.emitter.yield(1)
    let producer = Task { try await pair.emitter.yieldSuspending(2) }
    pair.session.cancel()
    await #expect(throws: (any Error).self) { try await producer.value }
}

@Test func ownerStreamFailureObserverDeliversOnceBeforeOrAfterTermination() async throws {
    enum Failure: Error { case injected }
    let first = InferenceSession<Int>.make(limits: try StreamLimits(), estimatedBytes: { _ in 1 })
    let early = EndCounter()
    first.session.observeFailure { _ in early.increment() }
    first.emitter.fail(Failure.injected)
    first.emitter.fail(Failure.injected)
    first.session.observeFailure { _ in early.increment() }
    #expect(early.count == 1)
    let second = InferenceSession<Int>.make(limits: try StreamLimits(), estimatedBytes: { _ in 1 })
    let late = EndCounter()
    second.emitter.fail(Failure.injected)
    second.session.observeFailure { _ in late.increment() }
    #expect(late.count == 1)
    let cancelled = InferenceSession<Int>.make(limits: try StreamLimits(), estimatedBytes: { _ in 1 })
    cancelled.session.observeFailure { _ in late.increment() }
    cancelled.session.cancel()
    #expect(late.count == 1)
}

@Test func boundedEventCountCanCarryLargePayloadWithoutByteCeiling() async throws {
    let source = String(repeating: "source", count: 20000)
    let pair = InferenceSession<String>.make(
        limits: try StreamLimits(capacity: 1, maximumEventBytes: nil), estimatedBytes: { $0.utf8.count })
    try pair.emitter.yield(source)
    let producer = Task {
        try await pair.emitter.yieldSuspending("next")
        pair.emitter.finish()
    }
    var iterator = pair.session.events.makeAsyncIterator()
    #expect(try await iterator.next() == source)
    #expect(try await iterator.next() == "next")
    try await producer.value
    #expect(try await iterator.next() == nil)
}
