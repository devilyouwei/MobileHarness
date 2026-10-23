import Foundation
import Testing

@testable import UI

@MainActor private func requestsEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw UIRequestError.unavailable }
        await Task.yield()
    }
}

@MainActor @Test func containerRequestsSeparateAcceptanceFromCompletion() async throws {
    let source = UIRequests<String, Int>()
    source.setAvailable(true)
    await #expect(throws: UIRequestError.unavailable) { try await source.submit("unconnected") }
    var inputs = try source.listen().makeAsyncIterator()
    #expect(throws: UIRequestError.duplicateConsumer) { try source.listen() }
    let result = Task { try await source.submit("hello") }
    let request = try #require(try await inputs.next())
    #expect(request.value == "hello")
    #expect(source.outstanding == 1 && source.acceptedCount == 0)
    #expect(request.accept())
    #expect(source.outstanding == 1 && source.acceptedCount == 1)
    #expect(request.complete(.success(42)))
    #expect(try await result.value == 42)
    #expect(source.outstanding == 0)
    #expect(!request.complete(.success(43)))
    source.stop()
}

@MainActor @Test func containerRequestsBoundAllOutstandingWorkIncludingAcceptedRequests() async throws {
    let source = UIRequests<Int, Int>()
    source.setAvailable(true)
    var inputs = try source.listen().makeAsyncIterator()
    let tasks = (0..<64).map { value in Task { try await source.submit(value) } }
    try await requestsEventually { source.outstanding == 64 }
    let first = try #require(try await inputs.next())
    #expect(first.accept())
    await #expect(throws: UIRequestError.capacityExceeded) { try await source.submit(65) }
    #expect(source.outstanding == 64)
    #expect(first.complete(.success(first.value)))
    for _ in 1..<64 {
        let request = try #require(try await inputs.next())
        #expect(request.accept())
        #expect(request.complete(.success(request.value)))
    }
    for (index, task) in tasks.enumerated() { #expect(try await task.value == index) }
    source.stop()
}

@MainActor @Test func containerRequestsFenceCancelledAndPreviousGenerationReplies() async throws {
    let source = UIRequests<String, Int>()
    source.setAvailable(true)
    var inputs = try source.listen().makeAsyncIterator()
    let cancelled = Task { try await source.submit("cancel") }
    let old = try #require(try await inputs.next())
    #expect(old.accept())
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(!old.complete(.success(1)))
    let pending = Task { try await source.submit("old generation") }
    let previous = try #require(try await inputs.next())
    source.setAvailable(false)
    await #expect(throws: UIRequestError.stale) { try await pending.value }
    source.setAvailable(true)
    #expect(!previous.accept() && !previous.complete(.success(2)))
    let current = Task { try await source.submit("new generation") }
    let next = try #require(try await inputs.next())
    #expect(next.generation != previous.generation)
    #expect(next.accept())
    next.complete(.failure(UIRequestError.stale))
    await #expect(throws: UIRequestError.stale) { try await current.value }
    source.stop()
}

@MainActor @Test func containerConsumerExitAndRootStopResolveWaiters() async throws {
    let source = UIRequests<Int, Int>()
    source.setAvailable(true)
    var inputs = try source.listen().makeAsyncIterator()
    let pending = Task { try await source.submit(1) }
    let receipt = try #require(try await inputs.next())
    source.stopListening()
    await #expect(throws: UIRequestError.consumerEnded) { try await pending.value }
    #expect(!receipt.complete(.success(1)))
    var replacement = try source.listen().makeAsyncIterator()
    let next = Task { try await source.submit(2) }
    _ = try await replacement.next()
    source.stop()
    await #expect(throws: UIRequestError.unavailable) { try await next.value }
    #expect(throws: UIRequestError.unavailable) { try source.listen() }
}

@MainActor @Test func controlRequestDoesNotWaitForOrdinaryCompletion() async throws {
    let source = UIRequests<String, String>()
    source.setAvailable(true)
    var ordinary = try source.listen().makeAsyncIterator()
    var controls = try source.listenControls().makeAsyncIterator()
    let work = Task { try await source.submit("work") }
    let accepted = try #require(try await ordinary.next())
    #expect(accepted.accept())
    #expect(!accepted.accept())
    let stop = Task { try await source.submitControl("stop") }
    let control = try #require(try await controls.next())
    #expect(control.value == "stop" && control.accept())
    await #expect(throws: UIRequestError.capacityExceeded) { try await source.submitControl("another stop") }
    #expect(control.complete(.success("stopped")))
    #expect(try await stop.value == "stopped")
    #expect(source.outstanding == 1)
    accepted.complete(.failure(CancellationError()))
    await #expect(throws: CancellationError.self) { try await work.value }
    source.stop()
}

@MainActor @Test func oldConsumerCleanupCannotCloseItsReplacementAndListeningIsControlOnly() async throws {
    let source = UIRequests<String, Int>()
    source.setAvailable(true)
    let first = try source.listen()
    let old = try source.listeningToken()
    source.stopListening(token: old)
    var replacement = try source.listen().makeAsyncIterator()
    let current = try source.listeningToken()
    source.stopListening(token: old)
    #expect(current != old)
    let result = Task { try await source.submit("replacement") }
    let request = try #require(try await replacement.next())
    #expect(request.accept() && request.complete(.success(7)))
    #expect(try await result.value == 7)
    withExtendedLifetime(first) {}
    source.stop()
    let ui = UIContainer()
    try ui.start()
    let ordinaryListening = try ui.home.listeningRequests.listen()
    var controls = try ui.home.listeningRequests.listenControls().makeAsyncIterator()
    await #expect(throws: UIRequestError.unavailable) { try await ui.home.listeningRequests.submit(.setEnabled(true)) }
    let listening = Task { try await ui.home.listeningRequests.submitControl(.setEnabled(true)) }
    let control = try #require(try await controls.next())
    #expect(control.accept() && control.complete(.success(())))
    try await listening.value
    withExtendedLifetime(ordinaryListening) {}
    await ui.stop()
}
