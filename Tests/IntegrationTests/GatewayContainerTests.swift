import Actions
import AgentCore
import AppLifecycle
import AppStorage
import CallRuntime
import Foundation
import FunctionContracts
import Testing

@testable import Agents
@testable import Gateway

private actor GatewayTestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
private actor GatewayCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
private let gatewayPath = ActionIdentifier(domain: "Fixture", module: "Execution", function: "perform")
private let gatewayResource = ResourceID(rawValue: "fixture.writer")
private enum GatewayTestError: Error { case cleanup }
private struct GatewayFixtureModule: CapabilityModule { let definitions: [ActionFunction] }

@MainActor private struct GatewayHarness {
    let actions: ActionsContainer
    let root: GatewayContainer
    let ports: GatewayCapabilities
    init(resources: [ResourceDefinition] = [], handler: @escaping ActionHandler = { _ in }) async throws {
        let actions = ActionsContainer()
        try actions.configure(
            BehaviorAssembly(capabilityModules: [
                GatewayFixtureModule(definitions: [
                    .init(
                        path: gatewayPath, displayName: "Fixture", kind: .finite, completion: "Joined.",
                        handler: handler)
                ])
            ]))
        try actions.start()
        let root = GatewayContainer()
        self.ports = try root.configureExecution(.init(executor: actions.execution, resources: resources))
        _ = try await ports.signals.register(address: "producer", incarnation: "generation") { _ in }
        self.actions = actions
        self.root = root
    }
    func stop() async throws {
        try await root.stop()
        try await actions.stop()
    }
}
private func gatewayJob(id: String = UUID().uuidString) throws -> ScheduledAction {
    let context = ActionExecutionContext(source: "producer", sessionID: "session", inputID: id)
    return try ScheduledAction(
        envelope: .init(
            source: context.source, sessionID: context.sessionID,
            inputID: id, schedulingID: id, context: context), call: .init(actionPath: gatewayPath), channel: "main",
        owner: .init(endpoint: "producer", incarnation: "generation", sessionID: "session"))
}
private func gatewaySignal(id: String = UUID().uuidString, cleanup: Bool = false) -> SignalEnvelope {
    .init(id: id, sessionID: "session", contract: "fixture.data", payloadBytes: 4, cleanup: cleanup)
}

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

@Test(.actionCatalog) @MainActor func gatewayRequiresConfigurationAndCannotRestartAfterStop() async throws {
    let root = GatewayContainer()
    await #expect(throws: GatewayFailure.self) { try await root.start() }
    #expect(throws: GatewayFailure.self) { _ = try root.capabilities }
    try await root.stop()
    await #expect(throws: GatewayFailure.self) { try await root.start() }
}

@Test(.actionCatalog) @MainActor func gatewayAcceptsOnlyOneConfigurationAndCachedPortsClose() async throws {
    let harness = try await GatewayHarness()
    #expect(throws: GatewayFailure.self) {
        try harness.root.configureExecution(.init(executor: harness.actions.execution))
    }
    await #expect(throws: GatewayContainerError.self) {
        try await harness.ports.actions.enqueue(invocation: gatewayJob())
    }
    async let one: Void = harness.root.start()
    async let two: Void = harness.root.start()
    _ = try await (one, two)
    async let closeOne: Void = harness.root.stop()
    async let closeTwo: Void = harness.root.stop()
    _ = try await (closeOne, closeTwo)
    #expect(harness.root.state == .stopped)
    await #expect(throws: Error.self) { try await harness.ports.actions.enqueue(invocation: gatewayJob()) }
    try await harness.actions.stop()
}

@Test(.actionCatalog) @MainActor func gatewayConfigurationFailureDoesNotPublishPorts() async throws {
    let harness = try await GatewayHarness()
    let root = GatewayContainer()
    let definition = ResourceDefinition(id: gatewayResource, allowedOwners: Set<String>()) {}
    #expect(throws: GatewayFailure.self) {
        try root.configureExecution(.init(executor: harness.actions.execution, resources: [definition, definition]))
    }
    #expect(root.state == .failed && !root.isAvailable)
    #expect(throws: GatewayFailure.self) { _ = try root.capabilities }
    try await root.stop()
    try await harness.stop()
}

@Test(.actionCatalog) @MainActor func gatewaySignalEndpointsAreGenericAndRejectStaleIncarnations() async throws {
    let harness = try await GatewayHarness()
    try await harness.root.start()
    let count = GatewayCounter()
    let source = try await harness.ports.signals.register(address: "source", incarnation: "first") { _ in }
    let target = try await harness.ports.signals.register(address: "target", incarnation: "first") { signal in
        #expect((signal.payload as? String) == "data")
        await count.increment()
    }
    try await harness.ports.signals.send(source: source, target: target, envelope: gatewaySignal(), payload: "data")
    _ = try await harness.ports.signals.register(address: "source", incarnation: "replacement") { _ in }
    await #expect(throws: SignalTransportError.staleEndpoint) {
        try await harness.ports.signals.send(source: source, target: target, envelope: gatewaySignal(), payload: "data")
    }
    #expect(await count.count == 1)
    try await harness.stop()
}

@Test(.actionCatalog) @MainActor func gatewayValidatesEnvelopeWithoutInterpretingBusinessPayload() async throws {
    let harness = try await GatewayHarness()
    try await harness.root.start()
    let source = try await harness.ports.signals.register(address: "source", incarnation: "one") { _ in }
    let target = try await harness.ports.signals.register(address: "target", incarnation: "one") { signal in
        #expect(signal.payload as? Int == 42)
    }
    try await harness.ports.signals.send(source: source, target: target, envelope: gatewaySignal(), payload: 42)
    await #expect(throws: SignalTransportError.invalidEnvelope) {
        try await harness.ports.signals.send(
            source: source, target: target,
            envelope: .init(id: "invalid", sessionID: "session", contract: "fixture.data", version: 2, payloadBytes: 4),
            payload: 42)
    }
    await #expect(throws: SignalTransportError.expired) {
        try await harness.ports.signals.send(
            source: source, target: target,
            envelope: .init(
                id: "expired", sessionID: "session", contract: "fixture.data", payloadBytes: 4,
                expiresAt: .now.advanced(by: .seconds(-1))), payload: 42)
    }
    try await harness.stop()
}

@Test(.actionCatalog) @MainActor func gatewayPauseFencesPortsAndResumeRetainsEndpoints() async throws {
    let count = GatewayCounter()
    let harness = try await GatewayHarness(handler: { _ in await count.increment() })
    try await harness.root.start()
    let endpoint = try await harness.ports.signals.register(address: "endpoint", incarnation: "one") { _ in }
    harness.root.invalidate()
    await #expect(throws: GatewayContainerError.self) {
        try await harness.ports.signals.send(
            source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    }
    await #expect(throws: GatewayContainerError.self) {
        try await harness.ports.actions.enqueue(invocation: gatewayJob())
    }
    try await harness.root.setForeground(true)
    try await harness.ports.signals.send(source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    let job = try gatewayJob()
    try await harness.ports.actions.enqueue(invocation: job)
    try await harness.ports.actions.finish(inputID: job.envelope.schedulingID, source: job.envelope.source)
    #expect(await count.count == 1)
    try await harness.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func gatewayPauseJoinsResourceCleanupBeforeResume()
    async throws
{
    let started = GatewayTestGate()
    let stopping = GatewayTestGate()
    let release = GatewayTestGate()
    let harness = try await GatewayHarness(resources: [
        ResourceDefinition(id: gatewayResource, allowedOwners: Set<String>()) {
            await stopping.release()
            await release.wait()
        }
    ])
    try await harness.root.start()
    let worker = Task {
        try await harness.ports.resources.run(resources: [gatewayResource], owner: nil, lease: nil) {
            await started.release()
            try await Task.sleep(for: .seconds(30))
        }
    }
    await started.wait()
    harness.root.invalidate()
    await stopping.wait()
    let resume = Task { try await harness.root.setForeground(true) }
    #expect(!harness.root.isAvailable)
    await release.release()
    try await resume.value
    _ = await worker.result
    #expect(harness.root.isAvailable)
    #expect(await harness.ports.resources.snapshot()[gatewayResource] == .unlocked)
    try await harness.stop()
}

@Test(.actionCatalog) @MainActor func gatewayRetainsCleanupFailureAcrossRepeatedStop() async throws {
    let started = GatewayTestGate()
    let harness = try await GatewayHarness(resources: [
        ResourceDefinition(id: gatewayResource, allowedOwners: Set<String>()) {
            throw GatewayTestError.cleanup
        }
    ])
    try await harness.root.start()
    let worker = Task {
        try await harness.ports.resources.run(resources: [gatewayResource], owner: nil, lease: nil) {
            await started.release()
            try await Task.sleep(for: .seconds(30))
        }
    }
    await started.wait()
    harness.root.invalidate()
    await #expect(throws: GatewayFailure.self) { try await harness.root.setForeground(true) }
    await #expect(throws: GatewayFailure.self) { try await harness.root.stop() }
    await #expect(throws: GatewayFailure.self) { try await harness.root.stop() }
    _ = await worker.result
    try await harness.actions.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func gatewayPauseJoinsAcceptedActionCleanup() async throws {
    let started = GatewayTestGate()
    let cleaning = GatewayTestGate()
    let release = GatewayTestGate()
    let harness = try await GatewayHarness { _ in
        await started.release()
        do { try await Task.sleep(for: .seconds(30)) } catch {
            await cleaning.release()
            await release.wait()
            throw error
        }
    }
    try await harness.root.start()
    try await harness.ports.actions.enqueue(invocation: gatewayJob())
    await started.wait()
    harness.root.invalidate()
    await cleaning.wait()
    let resume = Task { try await harness.root.setForeground(true) }
    #expect(!harness.root.isAvailable)
    await release.release()
    try await resume.value
    try await harness.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func gatewayStopJoinsAdmittedSignalReceivers() async throws {
    let started = GatewayTestGate()
    let cleaning = GatewayTestGate()
    let release = GatewayTestGate()
    let harness = try await GatewayHarness()
    try await harness.root.start()
    let endpoint = try await harness.ports.signals.register(address: "endpoint", incarnation: "one") { _ in
        await started.release()
        do { try await Task.sleep(for: .seconds(30)) } catch {
            await cleaning.release()
            await release.wait()
            throw error
        }
    }
    let send = Task {
        try await harness.ports.signals.send(
            source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    }
    await started.wait()
    let stopping = Task { try await harness.root.stop() }
    await cleaning.wait()
    #expect(harness.root.state == .stopping)
    await release.release()
    try await stopping.value
    _ = await send.result
    try await harness.actions.stop()
}

@Test(.actionCatalog) @MainActor func gatewayObservationScopesAreBoundedIsolatedAndRootOwned() async throws {
    let harness = try await GatewayHarness()
    try await harness.root.start()
    let configuration = GatewayConfiguration(executor: harness.actions.execution)
    let first = try harness.root.observations.open(configuration: configuration)
    #expect(throws: Error.self) { try harness.root.observations.open(configuration: configuration) }
    #expect(first.capabilities.signals !== harness.ports.signals)
    let endpoint = try await first.capabilities.signals.register(address: "isolated", incarnation: "one") { _ in }
    harness.root.invalidate()
    await #expect(throws: GatewayContainerError.self) {
        try await first.capabilities.signals.send(
            source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    }
    try await harness.root.setForeground(true)
    try await harness.root.observations.close(first)
    await #expect(throws: SignalTransportError.closed) {
        try await first.capabilities.signals.send(
            source: endpoint, target: endpoint, envelope: gatewaySignal(), payload: "data")
    }
    let next = try harness.root.observations.open(configuration: configuration)
    try await harness.root.stop()
    await #expect(throws: SignalTransportError.closed) {
        _ = try await next.capabilities.signals.register(address: "late", incarnation: "one") { _ in }
    }
    try await harness.actions.stop()
}

@Test(.actionCatalog) @MainActor func gatewayCancelledStartupClosesConfiguredPorts() async throws {
    let harness = try await GatewayHarness()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await harness.root.start()
    }
    await #expect(throws: GatewayFailure.self) { try await task.value }
    #expect(harness.root.state == .stopped && !harness.root.isAvailable)
    try await harness.actions.stop()
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
                _ = try gateway.configureExecution(.init(executor: root.execution))
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
                _ = try gateway.configureExecution(.init(executor: actions.execution))
            },
            stop: {
                #expect(actions.state == .stopped && gateway.state == .stopped)
                released = true
            }),
        ManagedService(id: "actions", dependencies: ["bindings"], start: { try actions.start() }, stop: actions.stop),
        ManagedService(id: "gateway", dependencies: ["actions"], start: gateway.start, stop: gateway.stop),
        ManagedService(id: "agents", dependencies: ["gateway"], start: { throw GatewayTestError.cleanup }, stop: {}),
    ])
    await #expect(throws: Error.self) { try await lifecycle.start() }
    #expect(released && !gateway.isAvailable)
}

@Test(.actionCatalog) @MainActor func gatewayExecutionRejectsUnboundAndStaleEndpointsBeforeEffects() async throws {
    let count = GatewayCounter()
    let harness = try await GatewayHarness { _ in await count.increment() }
    try await harness.root.start()
    await harness.ports.signals.unregister(address: "producer", incarnation: "generation")
    await #expect(throws: SignalTransportError.staleEndpoint) {
        try await harness.ports.actions.enqueue(invocation: gatewayJob())
    }
    _ = try await harness.ports.signals.register(address: "producer", incarnation: "replacement") { _ in }
    await #expect(throws: SignalTransportError.staleEndpoint) {
        try await harness.ports.actions.enqueue(invocation: gatewayJob())
    }
    #expect(await count.count == 0)
    try await harness.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func gatewayStopJoinsInProgressPreparation() async throws {
    let harness = try await GatewayHarness()
    let live = harness.actions.execution
    let started = GatewayTestGate()
    let release = GatewayTestGate()
    let prepared = ActionsExecutionPort(
        catalog: live.catalog,
        prepare: { input, syntax in
            await started.release()
            await release.wait()
            return try await live.prepare(input, syntax)
        }, execute: live.execute, discard: live.discard)
    let root = GatewayContainer()
    let ports = try root.configureExecution(.init(executor: prepared))
    _ = try await ports.signals.register(address: "producer", incarnation: "generation") { _ in }
    try await root.start()
    let admission = Task { try await ports.actions.enqueue(invocation: gatewayJob()) }
    await started.wait()
    let stopping = Task { try await root.stop() }
    while root.state != .stopping { await Task.yield() }
    #expect(root.state == .stopping)
    await release.release()
    try await stopping.value
    await #expect(throws: (any Error).self) { try await admission.value }
    #expect(root.state == .stopped)
    try await harness.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func gatewayReservesChannelCapacityBeforePreparation()
    async throws
{
    let harness = try await GatewayHarness()
    let live = harness.actions.execution
    let started = GatewayTestGate()
    let release = GatewayTestGate()
    let calls = GatewayCounter()
    let port = ActionsExecutionPort(
        catalog: live.catalog,
        prepare: { input, syntax in
            await calls.increment()
            await started.release()
            await release.wait()
            return try await live.prepare(input, syntax)
        }, execute: live.execute, discard: live.discard)
    let scheduler = ChannelScheduler(executor: port, capacityPerChannel: 1)
    let first = Task { try await scheduler.enqueue(invocation: gatewayJob()) }
    await started.wait()
    await #expect(throws: ActionSchedulingError.channelCapacityExceeded("main")) {
        try await scheduler.enqueue(invocation: gatewayJob())
    }
    #expect(await calls.count == 1)
    first.cancel()
    await release.release()
    _ = await first.result
    await scheduler.shutdown()
    try await harness.stop()
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
