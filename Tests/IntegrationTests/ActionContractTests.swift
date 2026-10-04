import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import Testing

private actor ContractGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = continuation
        }
    }

    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}

private actor ContractState {
    var effects = 0
    var animationPending = false
    var lastExecutionID: UUID?

    func commit(id: UUID? = nil) {
        effects += 1
        lastExecutionID = id
    }
    func setExpression() {
        effects += 1
        animationPending = true
    }
}

private let contractPath = ActionPath(module: "Fixture", function: "perform")

private func contractInvocation(path: ActionPath = contractPath) -> ActionInvocation {
    ActionInvocation(
        source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("contract")),
        call: ActionCall(actionPath: path, channel: "Ordered"))
}

private func contractDefinition(
    path: ActionPath = contractPath, kind: ActionDefinition.Kind = .finite,
    handler: @escaping ActionHandler = { _ in }
) -> ActionDefinition {
    ActionDefinition(
        path: path, displayName: "测试动作", kind: kind, completion: "Fixture operation acknowledged.", handler: handler)
}

@Test func actionDefinitionsRejectDuplicatesInvalidMetadataAndMissingGrants() throws {
    let definition = contractDefinition()
    #expect(throws: ActionExecutionError.duplicateDefinition(contractPath.executionIdentifier)) {
        try ActionRegistry(definitions: [definition, definition])
    }
    for completion in [" ", String(repeating: "x", count: 513)] {
        #expect(throws: ActionExecutionError.invalidDefinition(contractPath.executionIdentifier)) {
            try ActionRegistry(definitions: [
                ActionDefinition(
                    path: contractPath, displayName: "测试动作", kind: .finite, completion: completion, handler: { _ in })
            ])
        }
    }
    for displayName in ["", " \n", String(repeating: "界", count: 86)] {
        #expect(throws: ActionExecutionError.invalidDefinition(contractPath.executionIdentifier)) {
            try ActionRegistry(definitions: [
                ActionDefinition(
                    path: contractPath, displayName: displayName, kind: .finite,
                    completion: "Fixture acknowledged.", handler: { _ in })
            ])
        }
    }
    let malformed = ActionPath(module: "bad module", function: "perform")
    #expect(throws: ActionExecutionError.invalidDefinition(malformed.executionIdentifier)) {
        try ActionRegistry(definitions: [contractDefinition(path: malformed)])
    }
    #expect(throws: ActionExecutionError.definitionCapacityExceeded) {
        try ActionRegistry(definitions: Array(repeating: definition, count: 257))
    }
    let registry = try ActionRegistry(definitions: [definition])
    let model = try CapabilityRegistry(actions: [
        ActionRegistration(alias: "run", path: contractPath, defaultChannel: "Ordered")
    ])
    try registry.validate(capabilities: model)
    let missing = InternalAction(module: "Fixture", function: "missing", channel: "Ordered")
    #expect(throws: ActionExecutionError.missingHandler(missing.path.executionIdentifier)) {
        try registry.validate(capabilities: model.adding(internalActions: [missing]))
    }
    #expect(throws: ActionExecutionError.missingHandler(contractPath.executionIdentifier)) {
        try ActionRegistry().validate(capabilities: model)
    }
    #expect(try registry.definition(for: contractPath).kind == .finite)
}

@Test func assembledAgentCatalogsIncludeInternalActionsForStartupValidation() throws {
    let assistant = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    let speech = try SpeechPerceptionAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "SpeechPerception").capabilities)
    let vision = try VisionPerceptionAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "VisionPerception").capabilities)
    let synthesis = try AgentConfigurations.load(named: "SpeechSynthesis").capabilities
    let catalogs = [assistant, speech, vision, synthesis]
    let paths = Set(catalogs.flatMap { $0.actions.map(\.path) + $0.internalActions.map(\.path) })
    #expect(paths.contains(ActionPath(module: "Speech", function: "speak")))
    #expect(!paths.contains(ActionPath(module: "UI", function: "moveEyes")))
    #expect(vision.internalTools.contains { $0.path == "UI.moveEyes" })
    let registry = try ActionRegistry(definitions: paths.map { contractDefinition(path: $0) })
    for catalog in catalogs { try registry.validate(capabilities: catalog) }
}

@Test func invocationRejectsNonActionsAndDerivesCallFromEnvelope() throws {
    let input = AgentInput(sessionID: UUID(), payload: .event("contract"))
    #expect(throws: ActionExecutionError.invalidInvocation) {
        try ActionInvocation(envelope: OutputEnvelope(source: .assistant, input: input, output: .control("finish")))
    }
    let call = ActionCall(actionPath: contractPath, channel: "Ordered", parameters: ["count": "2"])
    let invocation = try ActionInvocation(
        envelope: OutputEnvelope(source: .assistant, input: input, output: .actionCall(call), sequence: 7))
    #expect(invocation.call == call.executionRequest)
    #expect(invocation.testEnvelope.inputID == input.id && invocation.testEnvelope.sequence == 7)
}

@Test func argumentReadersRejectMalformedValuesAndPreserveText() throws {
    let arguments = ActionArguments(["count": "3", "x": "-1", "text": " 你好 ", "emotion": "smile"])
    try arguments.validateAllowedKeys(["count", "x", "text", "emotion"])
    #expect(try arguments.requiredInt("count", range: 1...3) == 3)
    #expect(try arguments.requiredFiniteDouble("x", range: -1...1) == -1)
    #expect(try arguments.requiredString("text", maximumUTF8Bytes: 8) == " 你好 ")
    #expect(try arguments.requiredEnum("emotion", as: UIActions.Emotion.self) == .smile)
    #expect(throws: ActionArguments.ValidationError.invalidKeys) { try arguments.validateAllowedKeys(["count"]) }
    #expect(throws: ActionArguments.ValidationError.missing("missing")) {
        try arguments.requiredString("missing", maximumUTF8Bytes: 1)
    }
    #expect(throws: ActionArguments.ValidationError.invalidValue("text")) {
        try arguments.requiredString("text", maximumUTF8Bytes: 7)
    }
    for raw in ["nan", "inf", "-inf", "1e400", "1.01", "junk"] {
        #expect(throws: ActionArguments.ValidationError.invalidValue("x")) {
            try ActionArguments(["x": raw]).requiredFiniteDouble("x", range: -1...1)
        }
    }
    for raw in ["4", "1.5", String(repeating: "9", count: 100)] {
        #expect(throws: ActionArguments.ValidationError.invalidValue("count")) {
            try ActionArguments(["count": raw]).requiredInt("count", range: 1...3)
        }
    }
    #expect(throws: ActionArguments.ValidationError.invalidValue("emotion")) {
        try ActionArguments(["emotion": "SMILE"]).requiredEnum("emotion", as: UIActions.Emotion.self)
    }
}

@Test func presentationRejectsUnknownArgumentsBeforeEffects() async throws {
    let invocation = ActionInvocation(
        source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("contract")),
        call: ActionCall(
            actionPath: .init(module: "UI", function: "express"), channel: "Display",
            parameters: ["emotion": "smile", "unexpected": "value"]))
    await #expect(throws: UIActions.ExpressionError.invalidEmotion) {
        try await UIActions.setExpression(invocation: invocation) { _, _ in Issue.record("Unexpected effect") }
    }
}

@Test(.timeLimit(.minutes(1))) func finiteCompletionHoldsLaneButStateCommitDoesNotJoinAnimation() async throws {
    let started = ContractGate()
    let release = ContractGate()
    let state = ContractState()
    let setPath = ActionPath(module: "UI", function: "setExpression")
    let registry = try ActionRegistry(definitions: [
        contractDefinition { _ in
            await started.release()
            await release.wait()
        },
        contractDefinition(path: setPath, kind: .state) { invocation in
            try await UIActions.setExpression(invocation: invocation) { _, _ in await state.setExpression() }
        },
    ])
    let scheduler = ChannelScheduler(registry: registry)
    let first = contractInvocation()
    let second = try ActionInvocation(
        envelope: OutputEnvelope(
            source: .assistant,
            input: AgentInput(
                id: first.testEnvelope.inputID, sessionID: first.testEnvelope.sessionID,
                payload: .event("contract")),
            output: .actionCall(ActionCall(actionPath: setPath, channel: "Ordered", parameters: ["emotion": "smile"]))))
    let firstID = try await scheduler.enqueue(invocation: first)
    await started.wait()
    let secondID = try await scheduler.enqueue(invocation: second)
    let before = await scheduler.diagnosticSnapshot()
    #expect(before.records.filter { $0.executionID == secondID }.map(\.phase) == [.admitted])
    #expect(await state.effects == 0)
    await release.release()
    try await scheduler.finish(inputID: first.testEnvelope.inputID, source: AgentID(rawValue: "assistant"))
    #expect(await state.effects == 1)
    #expect(await state.animationPending)
    let after = await scheduler.diagnosticSnapshot()
    for id in [firstID, secondID] {
        #expect(after.records.filter { $0.executionID == id }.map(\.phase) == [.admitted, .started, .succeeded])
    }
    #expect(after.records.last?.kind == .state && after.records.last?.effect == .contractCompleted)
}

@Test func diagnosticEvictionNeverDiscardsActionsAndEachAdmissionGetsAnID() async throws {
    let state = ContractState()
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            contractDefinition { invocation in await state.commit(id: invocation.executionID) }
        ]),
        diagnosticCapacity: 2)
    let invocation = contractInvocation()
    let first = try await scheduler.enqueue(invocation: invocation)
    let second = try await scheduler.enqueue(invocation: invocation)
    #expect(first != second)
    try await scheduler.finish(inputID: invocation.testEnvelope.inputID, source: AgentID(rawValue: "assistant"))
    #expect(await state.effects == 2)
    #expect(await state.lastExecutionID == second)
    let snapshot = await scheduler.diagnosticSnapshot()
    #expect(snapshot.records.count == 2 && snapshot.evictedCount == 4)
    #expect(snapshot.records.last?.phase == .succeeded)
    let missing = contractInvocation(path: .init(module: "Missing", function: "handler"))
    await #expect(throws: ActionExecutionError.missingHandler(missing.call.actionPath)) {
        try await scheduler.enqueue(invocation: missing)
    }
    #expect(await scheduler.diagnosticSnapshot().evictedCount == 4)
}

@Test(.timeLimit(.minutes(1))) func cancellationDistinguishesQueuedFromPossiblyCommittedEffects() async throws {
    let committed = ContractGate()
    let cancelled = ContractGate()
    let cleanup = ContractGate()
    let state = ContractState()
    let registry = try ActionRegistry(definitions: [
        contractDefinition { _ in
            await state.commit()
            await committed.release()
            await withTaskCancellationHandler {
                await cleanup.wait()
            } onCancel: {
                Task { await cancelled.release() }
            }
            try Task.checkCancellation()
        }
    ])
    let scheduler = ChannelScheduler(registry: registry)
    let invocation = contractInvocation()
    let running = try await scheduler.enqueue(invocation: invocation)
    await committed.wait()
    let queued = try await scheduler.enqueue(invocation: invocation)
    let cancellation = Task {
        await scheduler.cancel(inputID: invocation.testEnvelope.inputID, source: AgentID(rawValue: "assistant"))
    }
    await cancelled.wait()
    let during = await scheduler.diagnosticSnapshot()
    #expect(during.records.last?.executionID == queued)
    #expect(during.records.last?.phase == .cancelled && during.records.last?.effect == .notStarted)
    #expect(!during.records.contains { $0.executionID == running && $0.phase == .cancelled })
    await cleanup.release()
    await cancellation.value
    #expect(await state.effects == 1)
    let after = await scheduler.diagnosticSnapshot()
    #expect(after.records.last?.executionID == running)
    #expect(after.records.last?.phase == .cancelled && after.records.last?.effect == .unknown)
}

private enum ContractFailure: Error, Equatable { case failed }

@Test func handlerFailureKeepsOriginalErrorAndRecordsUnknownEffects() async throws {
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [
            contractDefinition { _ in
                throw ContractFailure.failed
            }
        ]))
    let invocation = contractInvocation()
    try await scheduler.enqueue(invocation: invocation)
    try await scheduler.finish(inputID: invocation.testEnvelope.inputID, source: AgentID(rawValue: "assistant"))
    let snapshot = await scheduler.diagnosticSnapshot()
    #expect(snapshot.records.map(\.phase) == [.admitted, .started, .failed])
    #expect(snapshot.records.last?.effect == .unknown)
}

@Test func finiteExpressionRetainsModuleUntilPerformanceAndRestorationFinish() async throws {
    let entered = ContractGate()
    let animation = ContractGate()
    let restoring = ContractGate()
    let restored = ContractGate()
    let state = ContractState()
    let definition = UIActions.expressDefinition(handler: { invocation in
        try await UIActions.express(
            invocation: invocation,
            using: { _, _ in
                await entered.release()
                await animation.wait()
            },
            restoring: { _ in
                await restoring.release()
                await restored.wait()
            })
    })
    let setter = UIActions.setExpressionDefinition(handler: { invocation in
        try await UIActions.setExpression(invocation: invocation) { _, _ in await state.setExpression() }
    })
    let scheduler = ChannelScheduler(registry: try ActionRegistry(definitions: [definition, setter]))
    let input = AgentInput(sessionID: UUID(), payload: .event("expression"))
    let perform = ActionInvocation(
        source: .assistant, input: input,
        call: ActionCall(
            actionPath: .init(module: "UI", function: "express"), channel: "Display", parameters: ["emotion": "smile"]))
    let set = ActionInvocation(
        source: .assistant, input: input,
        call: ActionCall(
            actionPath: .init(module: "UI", function: "setExpression"), channel: "Another",
            parameters: ["emotion": "thinking"]))
    _ = try await scheduler.enqueue(invocation: perform)
    await entered.wait()
    _ = try await scheduler.enqueue(invocation: set)
    #expect(await state.effects == 0)
    await animation.release()
    await restoring.wait()
    #expect(await state.effects == 0)
    await restored.release()
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    #expect(await state.effects == 1)
    #expect(definition.kind == .finite && setter.kind == .state)
}

@Test func finiteExpressionCancellationAwaitsCleanupAndPreservesCancellation() async throws {
    let cleanupEntered = ContractGate()
    let cleanupFinished = ContractGate()
    let state = ContractState()
    let invocation = ActionInvocation(
        source: .assistant,
        input: AgentInput(sessionID: UUID(), payload: .event("expression")),
        call: ActionCall(
            actionPath: .init(module: "UI", function: "express"), channel: "Display",
            parameters: ["emotion": "smile"]))
    let task = Task {
        try await UIActions.express(
            invocation: invocation,
            using: { _, _ in
                throw CancellationError()
            },
            restoring: { _ in
                await cleanupEntered.release()
                await cleanupFinished.wait()
                await state.setExpression()
            })
    }
    await cleanupEntered.wait()
    #expect(await state.effects == 0)
    await cleanupFinished.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await state.effects == 1)
}

@Test func expressionCleanupFailureRetainsBothErrors() async throws {
    let invocation = ActionInvocation(
        source: .assistant,
        input: AgentInput(sessionID: UUID(), payload: .event("expression")),
        call: ActionCall(
            actionPath: .init(module: "UI", function: "express"), channel: "Display",
            parameters: ["emotion": "smile"]))
    do {
        try await UIActions.express(
            invocation: invocation,
            using: { _, _ in
                throw CancellationError()
            }, restoring: { _ in throw UIActions.ExpressionError.rendererUnavailable })
        Issue.record("Expected cleanup failure")
    } catch let failure as UIActions.ExpressionCleanupFailure {
        #expect(failure.primary is CancellationError)
        #expect(failure.cleanup as? UIActions.ExpressionError == .rendererUnavailable)
    }
}

@Test(arguments: [false, true])
func actionStoredResultsRetainSubsequentHandlerFailure(_ reported: Bool) async throws {
    let invocation = contractInvocation()
    let definition = contractDefinition { invocation in
        try await invocation.results.record(ActionReport(entries: [.init(path: "first", status: .succeeded)]))
        if reported { throw ActionReportedError(.failure(.disconnected)) }
        throw HarnessError.notRunning
    }
    let executor = ActionExecutor(registry: try ActionRegistry(definitions: [definition]))
    let completion = try await executor.execute(invocation)
    guard case .report(let report) = completion else {
        Issue.record("Expected report")
        return
    }
    #expect(report.entries.count == 1)
    #expect(report.executionFailure == (reported ? .disconnected : .handlerFailed))
    #expect(report.status == .partialFailure)
}

@Test func schedulerStoredReportDoesNotMaskCancellationOrHandlerFailure() async throws {
    let definition = contractDefinition { invocation in
        try await invocation.results.record(ActionReport(entries: [.init(path: "first", status: .succeeded)]))
        throw CancellationError()
    }
    let scheduler = ChannelScheduler(registry: try ActionRegistry(definitions: [definition]))
    let invocation = contractInvocation()
    try await scheduler.enqueue(invocation: invocation)
    try await scheduler.finish(inputID: invocation.context.inputID, source: AgentID(rawValue: "assistant"))
    let record = try #require(await scheduler.executionSnapshot().records.first)
    #expect(record.phase == .cancelled)
    guard case .report(let report)? = record.completion else {
        Issue.record("Expected report")
        return
    }
    #expect(report.entries.count == 1)
    #expect(report.executionFailure == .cancelled)
}

@Test func actionDefinitionBudgetOverridesRuntimeDefault() async throws {
    let definition = ActionDefinition(
        path: contractPath.executionIdentifier, displayName: "Timeout fixture",
        kind: .finite, completion: "Joined cleanup",
        estimatingDuration: { _ in
            try ActionExecutionBudget(expected: .zero, timeout: .milliseconds(10))
        }, handler: { _ in try await Task.sleep(for: .seconds(60)) })
    let executor = ActionExecutor(registry: try ActionRegistry(definitions: [definition]))
    let completion = try await executor.execute(contractInvocation())
    guard case .report(let report) = completion else {
        Issue.record("Expected timeout report")
        return
    }
    #expect(report.executionFailure == .timedOut)
    #expect(ActionExecutor.defaultTimeout == .seconds(30))
}
