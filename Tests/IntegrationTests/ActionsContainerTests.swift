import Actions
import AgentCore
import AppStorage
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Testing

private actor ContainerCounter {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}
private actor ContainerGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !opened { await withCheckedContinuation { waiter = $0 } } }
    func release() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
private enum ContainerFunctions {
    @Action(
        domain: "Fixture", module: "Container", title: "Perform",
        parameters: [
            .init("value", type: .integer, description: "A value from zero through nine")
        ])
    static func perform(invocation: any FunctionInput, using effect: @Sendable (Int) async -> Void) async throws {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["value"])
        let value = try arguments.requiredInt("value", range: 0...9)
        await effect(value)
    }
}
private struct ContainerModule: CapabilityModule { let definitions: [ActionFunction] }
private let containerPath = ActionIdentifier(domain: "Fixture", module: "Container", function: "perform")
private enum ContainerTestError: Error { case first, second }
private func containerInput(_ parameters: [String: String] = [:], path: ActionIdentifier = containerPath)
    -> FunctionInvocation
{
    .init(
        call: .init(actionPath: path, parameters: parameters),
        context: .init(source: "opaque-endpoint", sessionID: "session", inputID: UUID().uuidString),
        executionID: UUID().uuidString, results: ActionReportStore())
}
@MainActor private func containerRoot(
    _ functions: [ActionFunction], cleanup: [@MainActor @Sendable () async throws -> Void] = []
) throws -> ActionsContainer {
    let root = ActionsContainer()
    let bindings = try ActionBindingCatalog(
        definitions: functions.map {
            ActionBinding(function: $0, protocols: [.action, .tool], executionPolicy: .direct)
        })
    try root.configure(
        BehaviorAssembly(
            actionModules: [bindings.actions], toolModules: [bindings.tools],
            functions: FunctionRegistry(definitions: functions)), cleanup: cleanup)
    try root.start()
    return root
}

@Test(.actionCatalog) @MainActor func actionsRootIsInertAndRequiresConfiguration() async throws {
    let root = ActionsContainer()
    #expect(root.state == .cold)
    #expect(throws: ActionsContainerError.unavailable) { try root.start() }
    await #expect(throws: ActionsContainerError.unavailable) {
        try await root.execution.prepare(containerInput(), .action)
    }
    try await root.stop()
    #expect(root.state == .stopped)
    #expect(throws: ActionsContainerError.unavailable) { try root.start() }
}

@Test(.actionCatalog) @MainActor func actionsPrepareUsesTheSamePureArgumentDecoderBeforeAnyEffect() async throws {
    let counter = ContainerCounter()
    let function = ContainerFunctions.performDefinition(handler: { invocation in
        try await ContainerFunctions.perform(invocation: invocation, using: { await counter.record($0) })
    })
    let root = try containerRoot([function])
    await #expect(throws: ActionArguments.ValidationError.self) {
        try await root.execution.prepare(containerInput(["value": "10"]), .action)
    }
    await #expect(throws: ActionArguments.ValidationError.self) {
        try await root.execution.prepare(containerInput(["value": "1", "unknown": "x"]), .action)
    }
    #expect(await counter.values.isEmpty)
    let ticket = try await root.execution.prepare(containerInput(["value": "7"]), .action)
    #expect(await counter.values.isEmpty)
    #expect(try await root.execution.execute(ticket) == .completed)
    #expect(await counter.values == [7])
    await #expect(throws: ActionsContainerError.invalidPreparation) { try await root.execution.execute(ticket) }
    try await root.stop()
}

@Test(.actionCatalog) @MainActor func actionsPreparationIsBoundToItsContainerAndCatalogRevision() async throws {
    let function = ActionFunction(
        path: containerPath, displayName: "Fixture", kind: .finite, completion: "Joined.", handler: { _ in })
    let first = try containerRoot([function])
    let second = try containerRoot([function])
    let ticket = try await first.execution.prepare(containerInput(), .action)
    await #expect(throws: ActionsContainerError.invalidPreparation) { try await second.execution.execute(ticket) }
    #expect(try await first.execution.execute(ticket) == .completed)
    let stale = try await second.execution.prepare(containerInput(), .action)
    second.invalidate()
    try await second.setForeground(true)
    await #expect(throws: ActionsContainerError.invalidPreparation) { try await second.execution.execute(stale) }
    try await first.stop()
    try await second.stop()
}

@Test(.actionCatalog) @MainActor func actionsCatalogExposesCanonicalDescriptionsAndBothProtocols() async throws {
    let function = ContainerFunctions.performDefinition(handler: { _ in })
    let root = try containerRoot([function])
    let catalog = try await root.execution.catalog()
    #expect(catalog.entries.allSatisfy { $0.path == containerPath && $0.declaration == function.declaration })
    #expect(catalog.entries.contains { $0.protocols.contains(.action) })
    #expect(catalog.entries.contains { $0.protocols.contains(.tool) })
    let action = try await root.execution.prepare(containerInput(["value": "1"]), .action)
    let tool = try await root.execution.prepare(containerInput(["value": "1"]), .tool)
    #expect(try await root.execution.execute(action) == .completed)
    #expect(try await root.execution.execute(tool) == .completed)
    try await root.stop()
}

@Test(.actionCatalog) @MainActor func actionsRejectUnknownFunctionsAndInvalidBudgetsBeforeEffects() async throws {
    let counter = ContainerCounter()
    let function = ActionFunction(
        path: containerPath, displayName: "Fixture", kind: .finite, completion: "Joined.",
        dynamicTimeout: { _ in try ActionExecutionBudget(expected: .seconds(2), timeout: .seconds(1)) },
        handler: { _ in await counter.record(1) })
    let root = try containerRoot([function])
    await #expect(throws: Error.self) { try await root.execution.prepare(containerInput(), .action) }
    await #expect(throws: ActionExecutionError.self) {
        try await root.execution.prepare(
            containerInput(path: .init(domain: "Unknown", module: "Unknown", function: "unknown")), .action)
    }
    #expect(await counter.values.isEmpty)
    try await root.stop()
}

@Test(.actionCatalog, arguments: [false, true]) @MainActor func actionsValidateActualCompletionAndOutputSize(
    oversized: Bool
) async throws {
    let function = ActionFunction(
        path: containerPath, displayName: "Fixture", kind: oversized ? .finite : .state,
        completion: "Joined.", completing: { _ in .value(String(repeating: "x", count: oversized ? 65_537 : 1)) })
    let root = try containerRoot([function])
    let ticket = try await root.execution.prepare(containerInput(), .action)
    await #expect(throws: ActionExecutionError.invalidCompletion) { try await root.execution.execute(ticket) }
    try await root.stop()
}

@Test(.actionCatalog) @MainActor func actionsDoNotExecuteResourceEffectsWithoutALivePermit() async throws {
    let counter = ContainerCounter()
    let function = ActionFunction(
        path: containerPath, displayName: "Fixture", kind: .finite, completion: "Joined.",
        resources: [.init(rawValue: "fixture.writer")], handler: { _ in await counter.record(1) })
    let root = try containerRoot([function])
    let ticket = try await root.execution.prepare(containerInput(), .action)
    await #expect(throws: ActionsContainerError.missingBinding) { try await root.execution.execute(ticket) }
    #expect(await counter.values.isEmpty)
    try await root.stop()
}

@Test(.actionCatalog) @MainActor func actionsPreparationCapacityRejectsOverflowAndDiscardReleasesIt() async throws {
    let function = ActionFunction(
        path: containerPath, displayName: "Fixture", kind: .finite, completion: "Joined.", handler: { _ in })
    let root = try containerRoot([function])
    var tickets: [PreparedAction] = []
    for _ in 0..<1024 { tickets.append(try await root.execution.prepare(containerInput(), .action)) }
    await #expect(throws: ActionsContainerError.capacityExceeded) {
        try await root.execution.prepare(containerInput(), .action)
    }
    await root.execution.discard(tickets[0])
    _ = try await root.execution.prepare(containerInput(), .action)
    try await root.stop()
    await #expect(throws: ActionsContainerError.unavailable) { try await root.execution.execute(tickets[1]) }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func actionsStopJoinsActualHandlerCleanup() async throws {
    let started = ContainerGate()
    let cleaning = ContainerGate()
    let release = ContainerGate()
    let function = ActionFunction(
        path: containerPath, displayName: "Fixture", kind: .finite, completion: "Joined.",
        handler: { _ in
            await started.release()
            do { try await Task.sleep(for: .seconds(30)) } catch {
                await cleaning.release()
                await release.wait()
                throw error
            }
        })
    let root = try containerRoot([function])
    let ticket = try await root.execution.prepare(containerInput(), .action)
    let executing = Task { try await root.execution.execute(ticket) }
    await started.wait()
    let stopping = Task { try await root.stop() }
    await cleaning.wait()
    #expect(root.state == .stopping)
    await release.release()
    try await stopping.value
    _ = await executing.result
    #expect(root.state == .stopped)
}

@Test(.actionCatalog) @MainActor func actionsRetainPrimaryAndAdditionalCleanupFailures() async throws {
    let root = try containerRoot(
        [], cleanup: [{ throw ContainerTestError.first }, { throw ContainerTestError.second }])
    do {
        try await root.stop()
        Issue.record("Expected cleanup failure")
    } catch let failure as ActionsFailure {
        #expect(failure.code == .cleanupFailed)
        #expect(failure.cleanupErrors.count == 1)
        #expect(!failure.isCancellation)
    }
    await #expect(throws: ActionsFailure.self) { try await root.stop() }
    #expect(root.state == .failed)
}

@Test(.actionCatalog) @MainActor func actionsUseTheCanonicalStoreForBothCallProtocols() async throws {
    let counter = ContainerCounter()
    let canonical = ActionFunction(
        path: containerPath, displayName: "Canonical", kind: .finite,
        completion: "Joined.",
        completing: { _ in
            await counter.record(1)
            return .value("canonical")
        })
    let alternate = ActionFunction(
        path: containerPath, displayName: "Alternate", kind: .finite,
        completion: "Joined.",
        completing: { _ in
            await counter.record(2)
            return .value("alternate")
        })
    struct Calls: ActionModule { let definitions: [ActionBinding] }
    struct Tools: ToolModule { let definitions: [ActionBinding] }
    let assembly = try BehaviorAssembly(
        actionModules: [Calls(definitions: [.init(function: alternate)])],
        toolModules: [Tools(definitions: [.init(function: alternate, protocols: [.tool], executionPolicy: .direct)])],
        functions: FunctionRegistry(definitions: [canonical]))
    let root = ActionsContainer()
    try root.configure(assembly)
    try root.start()
    for syntax in [ActionExecutionDescriptor.CallProtocol.action, .tool] {
        let ticket = try await root.execution.prepare(containerInput(), syntax)
        #expect(ticket.descriptor.displayName == "Canonical")
        #expect(try await root.execution.execute(ticket) == .value("canonical"))
    }
    #expect(await counter.values == [1, 1])
    try await root.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func actionsCancellationRetainsIndependentCleanupFailure()
    async throws
{
    let started = ContainerGate()
    let function = ActionFunction(
        path: containerPath, displayName: "Fixture", kind: .finite, completion: "Joined.",
        completing: { _ in
            await started.release()
            do {
                try await Task.sleep(for: .seconds(30))
                return .completed
            } catch {
                return .report(
                    try ActionReport(entries: [
                        .init(path: "committed", status: .succeeded),
                        .init(path: "cleanup", status: .failed, code: .handlerFailed),
                    ]))
            }
        })
    let root = try containerRoot([function])
    let ticket = try await root.execution.prepare(containerInput(), .tool)
    let execution = Task { try await root.execution.execute(ticket) }
    await started.wait()
    execution.cancel()
    guard case .report(let report) = try await execution.value else {
        Issue.record("Cancellation discarded independent cleanup evidence")
        try await root.stop()
        return
    }
    #expect(report.status == .partialFailure && report.entries.count == 2)
    try await root.stop()
}
