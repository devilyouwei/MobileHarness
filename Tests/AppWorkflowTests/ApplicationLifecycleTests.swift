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
    #expect(values == [true, false, true])
    try await lifecycle.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func rapidReactivationJoinsEverySuspensionBeforeResumingAnyService() async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var events: [String] = []
    var cancellationFinished = false
    let lifecycle = try ApplicationLifecycle(services: [
        .init(
            id: "agents", start: {},
            foreground: { active in
                events.append("agents \(active)")
                if !active { cancellationFinished = true }
                if active, events.count > 2 { #expect(cancellationFinished) }
            }, stop: {}),
        .init(
            id: "native", dependencies: ["agents"], start: {},
            foreground: { active in
                events.append("native \(active)")
                if !active {
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                }
            }, stop: {}),
    ])
    try await lifecycle.start()
    try await lifecycle.waitForForeground()
    events.removeAll()
    lifecycle.setForeground(false)
    for await _ in entered.stream { break }
    lifecycle.setForeground(true)
    #expect(events == ["native false"] && !cancellationFinished)
    release.continuation.yield(())
    try await lifecycle.waitForForeground()
    #expect(events == ["native false", "agents false", "agents true", "native true"])
    #expect(cancellationFinished)
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

@MainActor private final class PreparationTestLatch {
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func homePreparationSkipsReadyAndSeriallyPreparesColdSteps() async {
    var events: [String] = []
    var loaded = false
    let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let workflow = ForegroundPreparation(
        steps: {
            [
                .init(
                    id: "warm",
                    isReady: {
                        events.append("check.warm")
                        return true
                    }, prepare: { _ in Issue.record("Already ready") }),
                .init(
                    id: "cold", isReady: { loaded },
                    prepare: { loading in
                        loading(true)
                        events.append("prepare.cold")
                        loaded = true
                    }),
                .init(
                    id: "last",
                    isReady: {
                        events.append("check.last")
                        return true
                    }, prepare: { _ in Issue.record("Already ready") }),
            ]
        }, canPrepare: { true }, project: { if $0 == .ready { ready.continuation.yield(()) } })
    workflow.setActive(true)
    workflow.setActive(true)
    for await _ in ready.stream { break }
    #expect(events == ["check.warm", "prepare.cold", "check.last", "check.warm", "check.last"])
    workflow.setActive(false)
    #expect(workflow.state == .inactive)
    await workflow.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func homePreparationDeactivationFencesLateSuccessAndJoinsBeforeReplacement() async {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = PreparationTestLatch()
    let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var attempts = 0
    var loaded = false
    var readyCount = 0
    let workflow = ForegroundPreparation(
        steps: {
            [
                .init(
                    id: "cold", isReady: { loaded },
                    prepare: { loading in
                        loading(true)
                        attempts += 1
                        entered.continuation.yield(())
                        await release.wait()
                        loaded = true
                    })
            ]
        }, canPrepare: { true },
        project: {
            if $0 == .ready {
                readyCount += 1
                ready.continuation.yield(())
            }
        })
    workflow.setActive(true)
    for await _ in entered.stream { break }
    workflow.setActive(false)
    #expect(workflow.state == .inactive)
    workflow.setActive(true)
    #expect(attempts == 1 && readyCount == 0)
    release.open()
    for await _ in ready.stream { break }
    #expect(attempts == 1 && readyCount == 1)
    await workflow.stop()
    await workflow.stop()
    workflow.refresh()
    workflow.setActive(true)
    #expect(workflow.state == .inactive && attempts == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func homePreparationDefersColdWorkDuringAnActiveSessionAndRetriesFailure() async {
    let updates = AsyncStream<ForegroundPreparation.State>.makeStream(bufferingPolicy: .bufferingOldest(16))
    var busy = true
    var fail = true
    var loaded = false
    var attempts = 0
    let workflow = ForegroundPreparation(
        steps: {
            [
                .init(
                    id: "cold", isReady: { loaded },
                    prepare: { loading in
                        loading(true)
                        attempts += 1
                        if fail { throw LifecycleTestFailure.start }
                        loaded = true
                    })
            ]
        }, canPrepare: { !busy }, project: { updates.continuation.yield($0) },
        onValidationFailure: { _, _ in Issue.record("Provider errors must retain their owning failure channel") })
    workflow.setActive(true)
    for await state in updates.stream { if state == .deferred { break } }
    #expect(attempts == 0)
    busy = false
    workflow.refresh()
    for await state in updates.stream {
        if case .failed(let component, _) = state {
            #expect(component == "cold")
            break
        }
    }
    fail = false
    workflow.refresh()
    for await state in updates.stream { if state == .ready { break } }
    #expect(attempts == 2)
    await workflow.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func homePreparationStopWaitsForNonCancellableNativePreparation() async {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = PreparationTestLatch()
    let stopping = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var stopped = false
    var projectedReady = false
    let workflow = ForegroundPreparation(
        steps: {
            [
                .init(
                    id: "native", isReady: { false },
                    prepare: { loading in
                        loading(true)
                        entered.continuation.yield(())
                        await release.wait()
                    })
            ]
        }, canPrepare: { true }, project: { if $0 == .ready { projectedReady = true } })
    workflow.setActive(true)
    for await _ in entered.stream { break }
    let task = Task {
        stopping.continuation.yield(())
        await workflow.stop()
        stopped = true
    }
    for await _ in stopping.stream { break }
    #expect(!stopped)
    release.open()
    await task.value
    #expect(stopped && !projectedReady)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func homePreparationDoesNotClaimReadyWhenALaterLoadEvictsEarlierResources() async {
    var firstLoaded = false
    var secondLoaded = false
    let failed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var ready = false
    var failures: [(String, ForegroundPreparation.ValidationError)] = []
    let workflow = ForegroundPreparation(
        steps: {
            [
                .init(
                    id: "first", isReady: { firstLoaded },
                    prepare: { loading in
                        loading(true)
                        firstLoaded = true
                    }),
                .init(
                    id: "second", isReady: { secondLoaded },
                    prepare: { loading in
                        loading(true)
                        secondLoaded = true
                        firstLoaded = false
                    }),
            ]
        }, canPrepare: { true },
        project: {
            if $0 == .ready { ready = true }
            if case .failed(let component, _) = $0 {
                #expect(component == "first")
                failed.continuation.yield(())
            }
        }, onValidationFailure: { component, error in failures.append((component, error)) })
    workflow.setActive(true)
    for await _ in failed.stream { break }
    #expect(!ready && !firstLoaded && secondLoaded)
    #expect(failures.count == 1 && failures.first?.0 == "first" && failures.first?.1 == .notReady)
    await workflow.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func homePreparationConfigurationChangesCoalesceAndCannotPublishAnOldReadyResult() async {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = PreparationTestLatch()
    let finished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var selection = 0
    var loadedSelection = -1
    var attempts = 0
    var readyCount = 0
    let workflow = ForegroundPreparation(
        steps: {
            [
                .init(
                    id: "selected", isReady: { loadedSelection == selection },
                    prepare: { loading in
                        loading(true)
                        let selected = selection
                        attempts += 1
                        entered.continuation.yield(())
                        await release.wait()
                        loadedSelection = selected
                    })
            ]
        }, canPrepare: { true },
        project: {
            if $0 == .ready {
                readyCount += 1
                finished.continuation.yield(())
            }
        })
    workflow.setActive(true)
    for await _ in entered.stream { break }
    selection = 1
    for _ in 0..<100 { workflow.refresh() }
    #expect(attempts == 1 && readyCount == 0)
    release.open()
    for await _ in finished.stream { break }
    #expect(attempts == 2 && readyCount == 1 && loadedSelection == 1)
    await workflow.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func homePreparationSeparatesLoadingFromChecksAndWarmReentry() async {
    var loaded = false
    var states: [ForegroundPreparation.State] = []
    let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let workflow = ForegroundPreparation(
        steps: {
            [
                .init(
                    id: "language",
                    isReady: {
                        #expect(states.last == .checking)
                        return loaded
                    },
                    prepare: { loading in
                        loading(true)
                        #expect(states.last == .preparing("language"))
                        loaded = true
                    })
            ]
        }, canPrepare: { true },
        project: {
            states.append($0)
            if $0 == .ready { ready.continuation.yield(()) }
        })
    workflow.setActive(true)
    for await _ in ready.stream { break }
    #expect(states.contains(.preparing("language")))
    for _ in 0..<2 {
        workflow.setActive(false)
        states.removeAll()
        workflow.setActive(true)
        for await _ in ready.stream { break }
        #expect(states == [.checking, .ready])
    }
    await workflow.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func homePreparationDoesNotShowLoadingForObjectAssemblyAndFencesLateReports() async {
    var loaded = false
    var states: [ForegroundPreparation.State] = []
    var lateReport: ForegroundPreparation.LoadingReport?
    let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let workflow = ForegroundPreparation(
        steps: {
            [
                .init(
                    id: "unmanaged", isReady: { loaded },
                    prepare: { report in
                        #expect(states.last == .checking)
                        lateReport = report
                        loaded = true
                    })
            ]
        }, canPrepare: { true },
        project: {
            states.append($0)
            if $0 == .ready { ready.continuation.yield(()) }
        })
    workflow.setActive(true)
    for await _ in ready.stream { break }
    #expect(!states.contains(.preparing("unmanaged")))
    workflow.setActive(false)
    lateReport?(true)
    #expect(workflow.state == .inactive)
    await workflow.stop()
}
