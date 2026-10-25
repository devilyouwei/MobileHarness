import Foundation
import Testing

@testable import Agents

@Test @MainActor func environmentInputsCoalesceCategoriesAndJoinShutdown() async throws {
    let delivered = AsyncStream<AppEnvironmentFact>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let gate = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let inputs = ApplicationEnvironmentInputs(
        deliver: { fact in
            delivered.continuation.yield(fact)
            if fact.sequence == 1 {
                var release = gate.stream.makeAsyncIterator()
                _ = await release.next()
            }
        }, failed: { _ in Issue.record("Unexpected environment failure") })
    var values = delivered.stream.makeAsyncIterator()
    inputs.report(.scene, value: "active")
    #expect(await values.next()?.sequence == 1)
    inputs.report(.modelPreparation, value: "loading")
    inputs.report(.modelPreparation, value: "idle")
    inputs.report(.devices, value: "connected")
    gate.continuation.yield(true)
    let preparation = try #require(await values.next())
    #expect(preparation.sequence == 3 && preparation.value == "idle")
    #expect(await values.next()?.sequence == 4)
    await inputs.shutdown()
    inputs.report(.scene, value: "closed")
    delivered.continuation.finish()
    #expect(await values.next() == nil)
}

@Test @MainActor func environmentDeliveryFailureIsReportedAndNextFactCanProceed() async throws {
    struct Failure: Error {}
    let failures = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let delivered = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let inputs = ApplicationEnvironmentInputs(
        deliver: { fact in
            if fact.value == "fail" { throw Failure() }
            delivered.continuation.yield(fact.value)
        }, failed: { failures.continuation.yield($0 is Failure) })
    var errors = failures.stream.makeAsyncIterator()
    inputs.report(.scene, value: "fail")
    #expect(await errors.next() == true)
    inputs.report(.scene, value: "recover")
    var values = delivered.stream.makeAsyncIterator()
    #expect(await values.next() == "recover")
    await inputs.shutdown()
}

@Test @MainActor func environmentShutdownJoinsActiveDeliveryAndSuppressesCancellation() async throws {
    let lifecycle = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(2))
    let inputs = ApplicationEnvironmentInputs(
        deliver: { _ in
            lifecycle.continuation.yield(true)
            defer { lifecycle.continuation.yield(false) }
            try await Task.sleep(for: .seconds(30))
        }, failed: { _ in Issue.record("Cancellation must not report an environment failure") })
    var events = lifecycle.stream.makeAsyncIterator()
    inputs.report(.scene, value: "active")
    #expect(await events.next() == true)
    await inputs.shutdown()
    #expect(await events.next() == false)
}
