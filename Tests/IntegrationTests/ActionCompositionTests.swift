import Actions
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import StorageCore
import Testing

private actor CompositionCounter {
    var count = 0
    func increment() { count += 1 }
}

@Test(.actionCatalog) func compositionPreservesEveryFailureAndContinuesNestedActions() async throws {
    let counter = CompositionCounter()
    let first = try ActionReport(entries: [
        .init(
            path: "motor3", status: .failed, code: .targetNotReached,
            details: ["motor": "3", "target": "1443", "observed": "1418"]),
        .init(path: "motor5", status: .failed, code: .feedbackLost, details: ["motor": "5", "target": "2048"]),
    ])
    let composition = try ActionComposition(
        .sequence([
            .action("pose", [ActionResource(rawValue: "nexarm.motor.3")], maximumResults: 2) { .report(first) },
            .repeated(
                2,
                .action("next", []) {
                    await counter.increment()
                    return .completed
                }),
            .delay(.zero),
        ]))
    let report = try await composition.run()
    #expect(report.status == .partialFailure)
    #expect(report.entries.count == 5)
    #expect(report.entries.compactMap(\.code) == [.targetNotReached, .feedbackLost])
    #expect(report.entries[0].details["observed"] == "1418")
    #expect(await counter.count == 2)
    #expect(composition.resources == [ActionResource(rawValue: "nexarm.motor.3")])
}

@Test(.actionCatalog) func compositionRejectsOverlappingParallelMotorsAndExcessResultsBeforeEffects() throws {
    let resource = ActionResource(rawValue: "nexarm.motor.4")
    let leaf = ActionComposition.Node.action("move", [resource]) { .completed }
    #expect(throws: ActionComposition.ConfigurationError.self) {
        try ActionComposition(.parallel([leaf, leaf]))
    }
    #expect(throws: ActionComposition.ConfigurationError.self) {
        try ActionComposition(.repeated(32, .repeated(32, leaf)))
    }
}

@Test(.actionCatalog) func reportedPartialFailureReleasesWaitAndDeliversAllIssues() async throws {
    let counter = CompositionCounter()
    let path = ActionPath(domain: "Composite", module: "Control", function: "run")
    let owner = ExecutionOwner(
        agent: .assistant, incarnation: UUID().uuidString, sessionID: UUID().uuidString)
    let input = AgentInput(id: UUID().uuidString, sessionID: owner.sessionID, payload: .event("composition"))
    let report = try ActionReport(entries: [
        .init(path: "first", status: .failed, code: .feedbackLost),
        .init(path: "second", status: .succeeded),
    ])
    let registry = try ActionRegistry(definitions: [
        ActionBinding(
            path: path, displayName: "组合", kind: .finite, completion: "Terminal report",
            completing: { invocation in
                if invocation.call.parameters["first"] == "true" { return .report(report) }
                await counter.increment()
                return .completed
            })
    ])
    let scheduler = ChannelScheduler(registry: registry)
    for first in [true, false] {
        let envelope = OutputEnvelope(
            source: .assistant, context: input.context,
            output: .actionCall(ActionCall(actionPath: path, channel: "Robot", parameters: ["first": String(first)])),
            taskScope: input.taskScope)
        try await scheduler.enqueue(invocation: ScheduledAction(envelope: envelope, owner: owner, feedback: .terminal))
    }
    try await scheduler.finish(inputID: input.id, source: AgentID(rawValue: "assistant"))
    await scheduler.finishResultDelivery()
    #expect(await counter.count == 1)
    let results = await scheduler.resultSnapshot().compactMap(\.result)
    #expect(results.count == 2)
    #expect(results.first?.status == .partialFailure)
    #expect(results.first?.report?.entries.map(\.code?.rawValue) == report.entries.map(\.code?.rawValue))
    #expect(results.last?.status == .succeeded)
}

@Test(.actionCatalog) func compositionCancellationKeepsPriorResultsAndDoesNotStartRemainingChildren() async throws {
    let counter = CompositionCounter()
    let composition = try ActionComposition(
        .sequence([
            .action("first", []) {
                await counter.increment()
                return .completed
            },
            .delay(.seconds(10)),
            .action("last", []) {
                await counter.increment()
                return .completed
            },
        ]))
    let task = Task { try await composition.run() }
    while await counter.count == 0 { await Task.yield() }
    task.cancel()
    let report = try await task.value
    #expect(report.status == .cancelled)
    #expect(report.entries.first?.status == .succeeded)
    #expect(report.entries.last?.status == .notStarted)
    #expect(await counter.count == 1)
}
