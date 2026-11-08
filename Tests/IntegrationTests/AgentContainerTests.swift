import AppLifecycle
import AppStorage
import Foundation
import Testing

@testable import Agents

@MainActor private final class ContainerLifecycleProbe {
    var starts = 0
    var stops = 0
    var fences = 0
    var transitions: [Bool] = []
    var failures: [AgentFailure] = []
    var start: @MainActor () async throws -> Void = {}
    var stop: @MainActor () async throws -> Void = {}
    var foreground: @MainActor (Bool) async throws -> Void = { _ in }
    lazy var lifecycle = AgentContainerLifecycle(
        start: { [unowned self] in
            starts += 1
            try await start()
        },
        invalidate: { [unowned self] in fences += 1 },
        foreground: { [unowned self] in
            transitions.append($0)
            try await foreground($0)
        },
        stop: { [unowned self] in
            stops += 1
            try await stop()
        },
        report: { [unowned self] in failures.append($0) })
}

private enum ContainerTestFailure: Error { case startup, cleanup }

@Test @MainActor func agentContainerConstructionIsInertAndScopesAreIndependent() async throws {
    let first = ContainerLifecycleProbe()
    let second = ContainerLifecycleProbe()
    #expect(!first.lifecycle.isAvailable && !second.lifecycle.isAvailable)
    #expect(first.starts == 0 && first.stops == 0 && first.fences == 0)
    try await first.lifecycle.start()
    try await second.lifecycle.start()
    try await first.lifecycle.stop()
    #expect(!first.lifecycle.isAvailable && second.lifecycle.isAvailable)
    #expect(second.stops == 0)
    try await second.lifecycle.stop()
}

@Test @MainActor func agentContainerConcurrentStartAndStopCoalesceAndStopIsTerminal() async throws {
    let probe = ContainerLifecycleProbe()
    async let first: Void = probe.lifecycle.start()
    async let second: Void = probe.lifecycle.start()
    _ = try await (first, second)
    #expect(probe.starts == 1 && probe.lifecycle.isAvailable)
    async let closeOne: Void = probe.lifecycle.stop()
    async let closeTwo: Void = probe.lifecycle.stop()
    _ = try await (closeOne, closeTwo)
    #expect(probe.stops == 1 && !probe.lifecycle.isAvailable)
    do {
        try await probe.lifecycle.start()
        Issue.record("A stopped root restarted")
    } catch { #expect(error.code == .stopped) }
    #expect(probe.starts == 1)
}

@Test @MainActor func agentContainerInvalidationFencesSynchronouslyAndResumeJoinsSuspension() async throws {
    let probe = ContainerLifecycleProbe()
    try await probe.lifecycle.start()
    probe.lifecycle.invalidate()
    #expect(!probe.lifecycle.isAvailable && probe.fences == 1)
    #expect(throws: AgentContainerError.self) { try probe.lifecycle.requireAvailable() }
    probe.lifecycle.invalidate()
    try await probe.lifecycle.setForeground(true)
    #expect(probe.transitions == [false, true] && probe.lifecycle.isAvailable)
    try await probe.lifecycle.stop()
}

@Test @MainActor func agentContainerStartupRollbackRetainsPrimaryAndCleanupErrors() async {
    let probe = ContainerLifecycleProbe()
    probe.start = { throw ContainerTestFailure.startup }
    probe.stop = { throw ContainerTestFailure.cleanup }
    do {
        try await probe.lifecycle.start()
        Issue.record("Expected startup failure")
    } catch {
        #expect(error.underlying as? ContainerTestFailure == .startup)
        #expect(error.cleanupErrors.first as? ContainerTestFailure == .cleanup)
        #expect(error.code == .cleanupFailed && !error.isCancellation)
    }
    #expect(probe.starts == 1 && probe.stops == 1 && !probe.lifecycle.isAvailable)
    do { try await probe.lifecycle.stop() } catch { #expect(error.code == .cleanupFailed) }
    #expect(probe.stops == 1)
}

@Test @MainActor func agentContainerStopCancelsAndJoinsInFlightStartup() async throws {
    let probe = ContainerLifecycleProbe()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var exited = false
    probe.start = {
        defer { exited = true }
        entered.continuation.yield(())
        try await Task.sleep(for: .seconds(60))
    }
    let opening = Task { try await probe.lifecycle.start() }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    try await probe.lifecycle.stop()
    #expect(exited && probe.stops == 1 && !probe.lifecycle.isAvailable)
    do {
        try await opening.value
        Issue.record("Expected startup cancellation")
    } catch { #expect((error as? AgentFailure)?.isCancellation == true) }
}

@Test @MainActor func agentContainerCancelledCallerRollsBackBeforeReturning() async {
    let probe = ContainerLifecycleProbe()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    probe.start = {
        entered.continuation.yield(())
        try await Task.sleep(for: .seconds(60))
    }
    let opening = Task { try await probe.lifecycle.start() }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    opening.cancel()
    do {
        try await opening.value
        Issue.record("Expected cancellation")
    } catch { #expect((error as? AgentFailure)?.isCancellation == true) }
    #expect(probe.stops == 1 && !probe.lifecycle.isAvailable)
}

@Test @MainActor func agentContainerStopBeforeStartIsTerminalAndCleansExactlyOnce() async throws {
    let probe = ContainerLifecycleProbe()
    try await probe.lifecycle.stop()
    try await probe.lifecycle.stop()
    #expect(probe.starts == 0 && probe.stops == 1)
    do {
        try await probe.lifecycle.start()
        Issue.record("Expected terminal rejection")
    } catch { #expect(error.code == .stopped) }
    do {
        try await probe.lifecycle.setForeground(true)
        Issue.record("Expected terminal rejection")
    } catch { #expect(error.code == .stopped) }
}

@Test func agentContainerFailureKeepsNativeIdentityAndCancellationCleanupDistinction() {
    let native = NSError(domain: "agent.container.test", code: 17)
    let original = AgentFailure(component: "visionPerception", operation: "start", underlying: native)
    let wrapped = AgentFailure(component: "root", operation: "start", underlying: original)
    #expect(wrapped.underlying as NSError === native)
    #expect(wrapped.source == original.source && wrapped.component == original.component)
    let cancellation = AgentFailure(component: "root", operation: "start", underlying: CancellationError())
    #expect(cancellation.isCancellation)
    let cleanup = AgentFailure(component: "root", operation: "stop", underlying: cancellation, cleanupErrors: [native])
    #expect(!cleanup.isCancellation && cleanup.code == .cleanupFailed)
    #expect(ApplicationContainer.failureDetails(cleanup)?.code == "cleanup.failed")
}

@Test @MainActor func agentContainerLateResumeCannotReopenAfterInvalidation() async throws {
    let probe = ContainerLifecycleProbe()
    try await probe.lifecycle.start()
    try await probe.lifecycle.setForeground(false)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    probe.foreground = { value in
        if value {
            entered.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }
    let resume = Task { try await probe.lifecycle.setForeground(true) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    probe.lifecycle.invalidate()
    #expect(!probe.lifecycle.isAvailable)
    release.continuation.yield(())
    try await resume.value
    #expect(probe.transitions == [false, true, false])
    #expect(!probe.lifecycle.isAvailable)
    try await probe.lifecycle.stop()
}

@Test @MainActor func agentContainerForegroundFailureClosesAdmissionAndRemainsObservable() async throws {
    let probe = ContainerLifecycleProbe()
    try await probe.lifecycle.start()
    probe.foreground = { _ in throw ContainerTestFailure.cleanup }
    do {
        try await probe.lifecycle.setForeground(false)
        Issue.record("Expected suspension failure")
    } catch { #expect(error.underlying as? ContainerTestFailure == .cleanup) }
    #expect(!probe.lifecycle.isAvailable && !probe.failures.isEmpty)
    do {
        try await probe.lifecycle.stop()
        Issue.record("Suspension failure was discarded")
    } catch { #expect(error.code == .cleanupFailed) }
    #expect(probe.stops == 1)
}

@Test @MainActor func agentContainerInitialInvalidationLeavesColdRootStartable() async throws {
    let probe = ContainerLifecycleProbe()
    probe.lifecycle.invalidate()
    probe.lifecycle.invalidate()
    #expect(!probe.lifecycle.isAvailable)
    #expect(probe.starts == 0 && probe.stops == 0 && probe.fences == 0)
    try await probe.lifecycle.start()
    #expect(probe.lifecycle.isAvailable && probe.starts == 1 && probe.failures.isEmpty)
    try await probe.lifecycle.stop()
}

@Test @MainActor func agentContainerHostInitialInactiveThenActiveStartsWithoutReload() async throws {
    let probe = ContainerLifecycleProbe()
    var failures = 0
    let host = try ApplicationLifecycle(services: [
        ManagedService(
            id: "agents",
            start: {
                do { try await probe.lifecycle.start() } catch {
                    if ApplicationContainer.failureDetails(error)?.isCancellation == true { throw CancellationError() }
                    throw error
                }
            }, invalidate: { probe.lifecycle.invalidate() },
            foreground: { try await probe.lifecycle.setForeground($0) },
            stop: { try await probe.lifecycle.stop() })
    ])
    host.onFailure = { _ in failures += 1 }
    host.setForeground(false)
    let opening = Task { try await host.start() }
    await Task.yield()
    #expect(probe.starts == 0 && probe.fences == 0 && failures == 0)
    host.setForeground(true)
    try await opening.value
    try await host.waitForForeground()
    #expect(host.state == .running && host.failure == nil && failures == 0)
    #expect(probe.starts == 1 && probe.lifecycle.isAvailable)
    try await host.stop()
    #expect(probe.stops == 1)
}

@Test @MainActor func agentContainerInvalidationDuringStartupStillCancelsAndJoinsRollback() async throws {
    let probe = ContainerLifecycleProbe()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var exited = false
    probe.start = {
        defer { exited = true }
        entered.continuation.yield(())
        try await Task.sleep(for: .seconds(60))
    }
    let opening = Task { try await probe.lifecycle.start() }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    probe.lifecycle.invalidate()
    #expect(!probe.lifecycle.isAvailable && probe.fences == 1)
    do {
        try await opening.value
        Issue.record("Expected startup invalidation cancellation")
    } catch { #expect((error as? AgentFailure)?.isCancellation == true) }
    #expect(exited && probe.stops == 1)
    do {
        try await probe.lifecycle.start()
        Issue.record("An invalidated startup scope restarted")
    } catch { #expect(error.code == .stopped) }
    try await probe.lifecycle.stop()
}

#if os(iOS)
    import Actions
    import ModelKitDefaults
    import PlatformKit
    import UI

    /// Compiled/executed by an iOS test host; the macOS lifecycle tests above do not replace this coverage.
    @available(iOS 27, *)
    @MainActor private func makeAgentContainerForIdentity(_ registry: ApplicationContainer) -> AgentContainer {
        registry.agents {
            let ui = registry.ui()
            let platform = registry.platform()
            let storage = registry.storage()
            let model = registry.model()
            let camera = platform.vision.camera
            let presentation = ui.camera
            let bluetooth = BluetoothWorkflow(
                state: ui.devices.presentation, link: platform.connectivity.bluetooth,
                makeDeviceRepository: { try storage.database.devices })
            let photos = CameraStorageFactory.make(
                repository: { try storage.database.media }, files: { try storage.files.file(storage.files.photos) })
            return AgentContainer(
                containerFailures: registry.containerFailures(), home: ui.home,
                settings: ui.settings, modelResources: ui.modelResources, navigation: ui.navigation,
                history: ui.history, devices: ui.devices, diagnostics: ui.diagnostics,
                repositories: {
                    try AgentRepositories(
                        assistantConversations: storage.database.assistantConversations,
                        assistantMessages: storage.database.assistantMessages,
                        assistantTasks: storage.database.assistantTasks,
                        writerMessages: storage.database.writerMessages,
                        writerExecutions: storage.database.writerExecutions,
                        agentMessages: storage.database.agentMessages, logs: storage.database.logs,
                        media: storage.database.media, devices: storage.database.devices)
                }, cache: storage.cache, files: storage.files, photos: photos,
                camera: camera, cameraPresentation: presentation, cameraUI: ui.camera, albumUI: ui.album,
                windows: ui.windows, island: ui.island,
                makeCamera: { connections in
                    CameraCoordinator(
                        camera: camera, presentation: presentation, photos: photos,
                        photoCues: platform.audio.cue(.camera),
                        makeRuntime: connections.makeRuntime, connectPerception: connections.connectPerception)
                }, bluetooth: bluetooth, audio: platform.audio,
                languageModels: model.language, speechModels: model.speech, visionModels: model.vision,
                modelArtifacts: model.artifacts, memoryPressure: { await model.handleMemoryPressure() })
        }
    }

    @available(iOS 27, *)
    @Test @MainActor func agentContainerRegistrySharesSevenStableChildrenAndIsolatesRoots() {
        let firstRegistry = ApplicationContainer(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let secondRegistry = ApplicationContainer(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let first = makeAgentContainerForIdentity(firstRegistry)
        let same = makeAgentContainerForIdentity(firstRegistry)
        let second = makeAgentContainerForIdentity(secondRegistry)
        func children(_ root: AgentContainer) -> [ObjectIdentifier] {
            [
                ObjectIdentifier(root.assistant), ObjectIdentifier(root.applicationControl),
                ObjectIdentifier(root.memory),
                ObjectIdentifier(root.photographer), ObjectIdentifier(root.speechPerception),
                ObjectIdentifier(root.speechSynthesis), ObjectIdentifier(root.visionPerception),
            ]
        }
        #expect(first === same && first !== second)
        #expect(children(first) == children(same) && Set(children(first)).count == 7)
        #expect(Set(children(first)).isDisjoint(with: children(second)))
        #expect(!first.isAvailable && !first.speechPerception.isReady && !second.isAvailable)
    }
#endif
