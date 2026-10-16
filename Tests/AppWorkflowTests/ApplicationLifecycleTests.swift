import AppLifecycle
import Foundation
import Testing

private enum LifecycleTestFailure: Error { case start, cleanup }

@Test @MainActor func lifecycleRejectsInvalidGraphsBeforeAnyEffect() throws {
    let a = ManagedService(id: "a", start: {}, stop: {})
    #expect(throws: ServiceGraphError.duplicate("a")) { try ApplicationLifecycle(services: [a, a]) }
    #expect(throws: ServiceGraphError.missingDependency(service: "b", dependency: "missing")) {
        try ApplicationLifecycle(services: [.init(id: "b", dependencies: ["missing"], start: {}, stop: {})])
    }
    #expect(throws: ServiceGraphError.cycle) {
        try ApplicationLifecycle(services: [
            .init(id: "a", dependencies: ["b"], start: {}, stop: {}),
            .init(id: "b", dependencies: ["a"], start: {}, stop: {}),
        ])
    }
    #expect(throws: ServiceGraphError.capacityExceeded) {
        try ApplicationLifecycle(services: (0..<65).map { .init(id: String($0), start: {}, stop: {}) })
    }
}

@Test @MainActor func lifecycleOrdersServicesAndJoinsDuplicateStop() async throws {
    var events: [String] = []
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "consumer", dependencies: ["foundation"], start: { events.append("start consumer") },
            stop: { events.append("stop consumer") }),
        .init(
            id: "foundation", start: { events.append("start foundation") }, stop: { events.append("stop foundation") }),
    ])
    try await lifecycle.start()
    try await lifecycle.start()
    async let first: Void = lifecycle.stop()
    async let second: Void = lifecycle.stop()
    _ = try await (first, second)
    #expect(events == ["start foundation", "start consumer", "stop consumer", "stop foundation"])
    #expect(lifecycle.state == .stopped)
    await #expect(throws: ServiceGraphError.closed) { try await lifecycle.start() }
}

@Test @MainActor func failedStartCleansPartialServiceAndRetainsEveryFailure() async throws {
    var events: [String] = []
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "foundation", start: { events.append("start foundation") },
            stop: {
                events.append("stop foundation")
                throw LifecycleTestFailure.cleanup
            }),
        .init(
            id: "consumer", dependencies: ["foundation"],
            start: {
                events.append("start consumer")
                throw LifecycleTestFailure.start
            },
            stop: {
                events.append("stop consumer")
                throw LifecycleTestFailure.cleanup
            }),
    ])
    do {
        try await lifecycle.start()
        Issue.record("Expected startup failure")
    } catch let error as ApplicationLifecycleFailure {
        #expect(error.service == "consumer")
        #expect(error.primary is LifecycleTestFailure)
        #expect(error.cleanup.map(\.service) == ["consumer", "foundation"])
    }
    #expect(events == ["start foundation", "start consumer", "stop consumer", "stop foundation"])
    #expect(lifecycle.state == .failed)
    do {
        try await lifecycle.stop()
        Issue.record("Rollback cleanup failure must prevent a successful replacement barrier")
    } catch let error as ApplicationLifecycleFailure {
        #expect(error.primary is LifecycleTestFailure)
        #expect(error.cleanup.map(\.service) == ["consumer", "foundation"])
    }
    await #expect(throws: ApplicationLifecycleFailure.self) { try await lifecycle.stop() }
    #expect(events.count == 4)
}

@Test @MainActor func backgroundInvalidatesBeforeSuspendedStartupAndFencesLateCompletion() async throws {
    var events: [String] = []
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "native",
            start: {
                events.append("start")
                entered.continuation.yield(())
                for await _ in release.stream { break }
                events.append("late start")
            }, invalidate: { events.append("invalidate") }, stop: { events.append("stop") })
    ])
    let startup = Task { try await lifecycle.start() }
    for await _ in entered.stream { break }
    lifecycle.setForeground(false)
    #expect(events == ["start", "invalidate"])
    release.continuation.yield(())
    _ = await startup.result
    #expect(events.contains("stop"))
    #expect(lifecycle.state == .suspended)
    #expect(lifecycle.failure == nil)
    await #expect(throws: CancellationError.self) { try await startup.value }
    lifecycle.setForeground(true)
    await #expect(throws: CancellationError.self) { try await lifecycle.start() }
    try await lifecycle.stop()
    #expect(events.filter { $0 == "stop" }.count == 1)
}

@Test @MainActor func shutdownKeepsAllCleanupFailuresAndNeverRestarts() async throws {
    let lifecycle = try ApplicationLifecycle(services: [
        .init(id: "first", start: {}, stop: { throw LifecycleTestFailure.cleanup }),
        .init(id: "second", start: {}, stop: { throw LifecycleTestFailure.cleanup }),
    ])
    try await lifecycle.start()
    do {
        try await lifecycle.stop()
        Issue.record("Expected cleanup failure")
    } catch let error as ApplicationLifecycleFailure {
        #expect(error.primary == nil)
        #expect(error.cleanup.map(\.service) == ["second", "first"])
    }
    #expect(lifecycle.state == .stopped)
    await #expect(throws: ApplicationLifecycleFailure.self) { try await lifecycle.stop() }
}

@Test @MainActor func cancelledPageWaiterDoesNotOwnRootStartup() async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var stopped = false
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "root",
            start: {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }, stop: { stopped = true })
    ])
    let page = Task { try await lifecycle.start() }
    for await _ in entered.stream { break }
    page.cancel()
    #expect(lifecycle.state == .starting && !stopped)
    release.continuation.yield(())
    _ = await page.result
    #expect(lifecycle.state == .running && !stopped)
    try await lifecycle.stop()
    #expect(stopped)
}

@Test @MainActor func sceneUpdatesCoalesceButNativeInvalidationIsImmediate() async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var values: [Bool] = []
    var invalidations = 0
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "root", start: {}, invalidate: { invalidations += 1 },
            foreground: { value in
                values.append(value)
                if values.count == 1 {
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                }
            }, stop: {})
    ])
    try await lifecycle.start()
    for await _ in entered.stream { break }
    lifecycle.setForeground(false)
    lifecycle.setForeground(true)
    #expect(invalidations == 1)
    release.continuation.yield(())
    try await lifecycle.waitForForeground()
    #expect(values == [true, true])
    try await lifecycle.stop()
}

@Test @MainActor func sceneFailureIsReportedAndRetainsItsProducer() async throws {
    var reported: [String] = []
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "native", start: {},
            foreground: { value in
                if !value { throw LifecycleTestFailure.cleanup }
            }, stop: {})
    ])
    lifecycle.onFailure = { failure in reported.append(failure.service ?? "") }
    try await lifecycle.start()
    try await lifecycle.waitForForeground()
    lifecycle.setForeground(false)
    await #expect(throws: ApplicationLifecycleFailure.self) { try await lifecycle.waitForForeground() }
    #expect(reported == ["native"])
    #expect(lifecycle.failure?.primary is LifecycleTestFailure)
    try await lifecycle.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor func startupBeforeActiveWaitsWithoutFailureOrNativeEffects() async throws {
    var starts = 0
    var failures = 0
    let lifecycle = try ApplicationLifecycle(services: [.init(id: "native", start: { starts += 1 }, stop: {})])
    lifecycle.onFailure = { _ in failures += 1 }
    lifecycle.setForeground(false)
    let startup = Task { try await lifecycle.start() }
    while lifecycle.state != .starting { await Task.yield() }
    lifecycle.setForeground(false)
    #expect(starts == 0 && failures == 0 && lifecycle.failure == nil)
    lifecycle.setForeground(true)
    try await startup.value
    #expect(lifecycle.state == .running && starts == 1 && failures == 0)
    try await lifecycle.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor func stoppingBeforeFirstActiveReleasesStartupWaitWithoutErrorNotice()
    async throws
{
    var starts = 0
    var failures = 0
    let lifecycle = try ApplicationLifecycle(services: [.init(id: "native", start: { starts += 1 }, stop: {})])
    lifecycle.onFailure = { _ in failures += 1 }
    lifecycle.setForeground(false)
    let startup = Task { try await lifecycle.start() }
    while lifecycle.state != .starting { await Task.yield() }
    try await lifecycle.stop()
    await #expect(throws: CancellationError.self) { try await startup.value }
    #expect(lifecycle.state == .stopped && starts == 0 && failures == 0 && lifecycle.failure == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor func quickForegroundCannotReuseCancelledStartupOrPublishPreparationFailure()
    async throws
{
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var starts = 0
    var stops = 0
    var failures = 0
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "native",
            start: {
                starts += 1
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }, stop: { stops += 1 })
    ])
    lifecycle.onFailure = { _ in failures += 1 }
    let startup = Task { try await lifecycle.start() }
    for await _ in entered.stream { break }
    lifecycle.setForeground(false)
    lifecycle.setForeground(true)
    release.continuation.yield(())
    await #expect(throws: CancellationError.self) { try await startup.value }
    #expect(lifecycle.state == .suspended && failures == 0 && starts == 1 && stops == 1)
    await #expect(throws: CancellationError.self) { try await lifecycle.start() }
    try await lifecycle.stop()
    let replacement = try ApplicationLifecycle(services: [.init(id: "native", start: { starts += 1 }, stop: {})])
    try await replacement.start()
    #expect(replacement.state == .running && starts == 2)
    try await replacement.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor func backgroundRollbackFailureStillReportsAndBlocksReplacementBarrier()
    async throws
{
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var failures = 0
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "native",
            start: {
                entered.continuation.yield(())
                try await Task.sleep(for: .seconds(60))
            }, stop: { throw LifecycleTestFailure.cleanup })
    ])
    lifecycle.onFailure = { _ in failures += 1 }
    let startup = Task { try await lifecycle.start() }
    for await _ in entered.stream { break }
    lifecycle.setForeground(false)
    await #expect(throws: ApplicationLifecycleFailure.self) { try await startup.value }
    #expect(lifecycle.state == .failed && failures == 1)
    #expect(lifecycle.failure?.primary is CancellationError)
    #expect(lifecycle.failure?.cleanup.map(\.service) == ["native"])
    await #expect(throws: ApplicationLifecycleFailure.self) { try await lifecycle.stop() }
}

@Test @MainActor func serviceCancellationInForegroundRemainsARealStartupFailure() async throws {
    var failures = 0
    let lifecycle = try ApplicationLifecycle(services: [
        .init(id: "service", start: { throw CancellationError() }, stop: {})
    ])
    lifecycle.onFailure = { _ in failures += 1 }
    await #expect(throws: ApplicationLifecycleFailure.self) { try await lifecycle.start() }
    #expect(lifecycle.state == .failed && failures == 1 && lifecycle.failure?.service == "service")
    try await lifecycle.stop()
}
