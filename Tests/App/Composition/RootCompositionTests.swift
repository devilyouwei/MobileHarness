import Actions
import Agents
import AppLifecycle
import AppStorage
import Foundation
import Gateway
import ModelKitDefaults
import PlatformKit
import Synchronization
import Testing

@testable import UI

@Test @MainActor func platformRegistrationIsRootLocal() async throws {
    let registry = ApplicationContainer(root: URL.temporaryDirectory)
    let root = registry.platform()
    #expect(root === registry.platform())
    #expect(root.audio === registry.audio())
    #expect(root.vision === registry.vision())
    #expect(root.connectivity === registry.connectivity())
    #expect(root !== ApplicationContainer(root: URL.temporaryDirectory).platform())
    #expect(!root.isAvailable)
    #expect(await root.connectivity.bluetooth.status().phase == .disconnected)
    try await root.stop()
}

@Test @MainActor func uiRegistrationSharesCameraWithItsRootAndIsolatesScopes() async throws {
    let registry = ApplicationContainer(root: URL.temporaryDirectory)
    let root = registry.ui()
    #expect(root === registry.ui())
    #expect(root.camera === registry.cameraPresentation())
    #expect(root.camera.state === registry.cameraPresentation().state)
    let next = ApplicationContainer(root: URL.temporaryDirectory).ui()
    #expect(root !== next)
    #expect(root.camera.state !== next.camera.state)
    #expect(!root.isAvailable)
    #expect(!root.camera.snapshot.isEnabled)
    try root.start()
    #expect(root.isAvailable)
    #expect(!next.isAvailable)
    await root.stop()
    await next.stop()
}

@MainActor private final class UIServiceTrace {
    var events: [String] = []
}

@Test @MainActor func uiLifecycleOrdersConsumersBeforeRootCleanup() async throws {
    let root = UI.UIContainer()
    let trace = UIServiceTrace()
    let lifecycle = try AppLifecycle.ApplicationLifecycle(services: [
        AppLifecycle.ManagedService(
            id: "consumer", dependencies: ["ui"],
            start: {
                #expect(root.isAvailable)
                trace.events.append("consumer.start")
            }, stop: { trace.events.append("consumer.stop") }),
        AppLifecycle.ManagedService(
            id: "ui",
            start: {
                try root.start()
                trace.events.append("ui.start")
            }, invalidate: root.invalidate, foreground: { try root.setForeground($0) },
            stop: {
                await root.stop()
                trace.events.append("ui.stop")
            }),
    ])
    try await lifecycle.start()
    try await lifecycle.waitForForeground()
    lifecycle.setForeground(false)
    #expect(!root.isAvailable)
    try await lifecycle.waitForForeground()
    lifecycle.setForeground(true)
    try await lifecycle.waitForForeground()
    #expect(root.isAvailable)
    try await lifecycle.stop()
    #expect(trace.events == ["ui.start", "consumer.start", "consumer.stop", "ui.stop"])
    #expect(!root.isAvailable)
    #expect(throws: UI.UIFailure.self) { try root.start() }
}

private enum UIConsumerFailure: Error, Equatable { case start }
@Test @MainActor func uiLifecycleRollsBackAfterConsumerStartupFailure() async throws {
    let root = UI.UIContainer()
    let lifecycle = try AppLifecycle.ApplicationLifecycle(services: [
        AppLifecycle.ManagedService(
            id: "ui", start: { try root.start() }, invalidate: root.invalidate, stop: { await root.stop() }),
        AppLifecycle.ManagedService(
            id: "consumer", dependencies: ["ui"], start: { throw UIConsumerFailure.start }, stop: {}),
    ])
    do {
        try await lifecycle.start()
        Issue.record("Consumer startup must fail")
    } catch let failure as AppLifecycle.ApplicationLifecycleFailure {
        #expect(failure.primary as? UIConsumerFailure == .start)
        #expect(failure.cleanup.isEmpty)
    }
    #expect(!root.isAvailable)
    #expect(throws: UI.UIFailure.self) { try root.start() }
}

@Test @MainActor func modelRegistrationSharesFourPortsAndIsolatesRoots() async throws {
    let registry = ApplicationContainer(root: URL.temporaryDirectory)
    let root = registry.model()
    #expect(root === registry.model())
    #expect(root.language === registry.languageModels())
    #expect(root.speech === registry.speechModels())
    #expect(root.vision === registry.visionModels())
    #expect(root.artifacts === registry.modelArtifactsCapability())
    let other = ApplicationContainer(root: URL.temporaryDirectory).model()
    #expect(root !== other)
    #expect(root.language !== other.language)
    try await root.stop()
    try await other.stop()
}

private enum RootCompositionFailure: Error { case startup }

@Test(.actionCatalog) @MainActor func gatewayAndActionsRegistrationsAreUniquePerAppScope() async throws {
    let first = ApplicationContainer(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let second = ApplicationContainer(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    #expect(first.gateway() === first.gateway())
    #expect(first.actions() === first.actions())
    #expect(first.gateway() !== second.gateway())
    #expect(first.actions() !== second.actions())
    #expect(first.gateway().state == .cold && first.actions().state == .cold)
    #expect(!first.gateway().isAvailable)
    try await first.gateway().stop()
    try await first.actions().stop()
    try await second.gateway().stop()
    try await second.actions().stop()
}

@Test @MainActor func hostOrdersActionsGatewayAgentsAndRetainsBindingsThroughCleanup() async throws {
    var order: [String] = []
    let root = ActionsContainer()
    let gateway = GatewayContainer()
    let lifecycle = try ApplicationLifecycle(services: [
        ManagedService(
            id: "bindings",
            start: {
                try root.configure(BehaviorAssembly(capabilityModules: []))
                _ = try gateway.configureExecution(.init(engine: root.configureExecution(resources: [])))
                order.append("bindings")
            },
            stop: {
                #expect(gateway.state == .stopped && root.state == .stopped)
                order.append("unbind")
            }),
        ManagedService(
            id: "actions", dependencies: ["bindings"],
            start: {
                try root.start()
                order.append("actions")
            },
            stop: {
                #expect(gateway.state == .stopped)
                try await root.stop()
                order.append("stopActions")
            }),
        ManagedService(
            id: "gateway", dependencies: ["actions"],
            start: {
                try await gateway.start()
                order.append("gateway")
            },
            stop: {
                #expect(root.state == .running)
                try await gateway.stop()
                order.append("stopGateway")
            }),
        ManagedService(
            id: "agents", dependencies: ["gateway"],
            start: {
                #expect(gateway.isAvailable)
                order.append("agents")
            },
            stop: {
                #expect(gateway.isAvailable && root.state == .running)
                order.append("stopAgents")
            }),
    ])
    try await lifecycle.start()
    try await lifecycle.stop()
    #expect(
        order == ["bindings", "actions", "gateway", "agents", "stopAgents", "stopGateway", "stopActions", "unbind"])
}

@Test @MainActor func hostRollsBackActionsAndGatewayBeforeReleasingFailedBindings() async throws {
    let actions = ActionsContainer()
    let gateway = GatewayContainer()
    var released = false
    let lifecycle = try ApplicationLifecycle(services: [
        ManagedService(
            id: "bindings",
            start: {
                try actions.configure(BehaviorAssembly(capabilityModules: []))
                _ = try gateway.configureExecution(.init(engine: actions.configureExecution(resources: [])))
            },
            stop: {
                #expect(actions.state == .stopped && gateway.state == .stopped)
                released = true
            }),
        ManagedService(id: "actions", dependencies: ["bindings"], start: { try actions.start() }, stop: actions.stop),
        ManagedService(id: "gateway", dependencies: ["actions"], start: gateway.start, stop: gateway.stop),
        ManagedService(
            id: "agents", dependencies: ["gateway"], start: { throw RootCompositionFailure.startup }, stop: {}),
    ])
    await #expect(throws: Error.self) { try await lifecycle.start() }
    #expect(released && !gateway.isAvailable)
}

@Test @MainActor func appRegistryRetainsExplicitActionsRoot() async throws {
    let registry = ApplicationContainer(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let root = ActionsContainer()
    registry.registerActions(root)
    #expect(registry.actions() === root)
    #expect(registry.actions() === root)
    try await root.stop()
    #expect(registry.actions().state == .stopped)
}

@Test @MainActor func memoryPressureRelayReleasesOncePerWarningAndJoinsOnStop() async throws {
    let pair = AsyncThrowingStream<MemoryWarning, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let released = AsyncStream<Void>.makeStream()
    let detached = Mutex(false)
    let relay = MemoryPressureRelay(
        listen: {
            StateSignalListener(
                source: .init(producer: "test.memory", generation: "g", delivery: .latest), stream: pair.stream,
                detach: {
                    detached.withLock { $0 = true }
                    pair.continuation.finish()
                })
        },
        release: { released.continuation.yield(()) }, failed: { Issue.record("unexpected failure: \($0)") })
    try relay.start()
    try relay.start()
    pair.continuation.yield(MemoryWarning(observedAt: .now))
    var events = released.stream.makeAsyncIterator()
    #expect(await events.next() != nil)
    await relay.stop()
    await relay.stop()
    #expect(detached.withLock { $0 })
    released.continuation.finish()
    #expect(await events.next() == nil)
}

@Test @MainActor func memoryPressureRelayReportsSubscriptionFailures() async throws {
    let unavailable = MemoryPressureRelay(
        listen: { throw PlatformError.unavailable }, release: {}, failed: { _ in })
    #expect(throws: PlatformError.self) { try unavailable.start() }

    let pair = AsyncThrowingStream<MemoryWarning, any Error>.makeStream()
    let failures = AsyncStream<String>.makeStream()
    let relay = MemoryPressureRelay(
        listen: {
            StateSignalListener(
                source: .init(producer: "test.memory", generation: "g", delivery: .latest), stream: pair.stream,
                detach: {})
        },
        release: {}, failed: { failures.continuation.yield(String(describing: $0)) })
    try relay.start()
    pair.continuation.finish(throwing: NativeSubscriptionError.overflow)
    var iterator = failures.stream.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    await relay.stop()
}
