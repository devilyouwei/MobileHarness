import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import StorageCore
import Testing

@testable import Agents

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

@Test(.actionCatalog, arguments: [false, true])
func compositionSequencePolicyStopsOnlyDependentWork(_ stop: Bool) async throws {
    let counter = CompositionCounter()
    let composition = try ActionComposition(
        .sequence(
            [
                .action("open", []) { throw CameraControlError.permissionDenied },
                .parallel([
                    .action("capture", []) {
                        await counter.increment()
                        return .completed
                    },
                    .repeated(
                        2,
                        .action("other", []) {
                            await counter.increment()
                            return .completed
                        }),
                ]),
            ], failurePolicy: stop ? .stopOnFailure : .continueOnFailure))
    let report = try await composition.run()
    #expect(await counter.count == (stop ? 0 : 3))
    #expect(report.entries.count == 4)
    #expect(report.entries.first?.code?.rawValue == "permissionDenied")
    #expect(
        report.entries.dropFirst().allSatisfy {
            $0.status == (stop ? .notStarted : .succeeded) && $0.code == (stop ? .dependencyFailed : nil)
        })
}

@Test(.actionCatalog) func compositionNestedPoliciesPreserveOuterContinue() async throws {
    let counter = CompositionCounter()
    let report = try await ActionComposition(
        .sequence([
            .sequence(
                [
                    .action("failed", []) { .report(.failure(.handlerFailed)) },
                    .action("blocked", []) {
                        await counter.increment()
                        return .completed
                    },
                ], failurePolicy: .stopOnFailure),
            .action("recovery", []) {
                await counter.increment()
                return .completed
            },
        ])
    ).run()
    #expect(await counter.count == 1)
    #expect(report.entries.map(\.status) == [.failed, .notStarted, .succeeded])
}

@Test(.actionCatalog, arguments: [false, true])
func compositionLeafTimeoutFollowsSelectedPolicy(_ stop: Bool) async throws {
    let counter = CompositionCounter()
    let report = try await ActionComposition(
        .sequence(
            [
                .action("slow", [], budget: .init(expected: .zero, timeout: .milliseconds(10))) {
                    try await Task.sleep(for: .seconds(10))
                    return .completed
                },
                .action("never", []) {
                    await counter.increment()
                    return .completed
                },
            ], failurePolicy: stop ? .stopOnFailure : .continueOnFailure)
    ).run()
    #expect(await counter.count == (stop ? 0 : 1))
    #expect(report.hasFailures)
    #expect(report.entries.last?.status == (stop ? .notStarted : .succeeded))
    #expect(report.entries.last?.code == (stop ? .dependencyFailed : nil))
}

@Test(.actionCatalog, arguments: [false, true])
func compositionTypedResultPreservesPayloadAndFailureEvidence(_ fail: Bool) async throws {
    let input = FunctionInvocation(
        call: .init(actionPath: .init(domain: "Fixture", module: "Composite", function: "capture")),
        context: .init(source: "assistant", sessionID: "session", inputID: "input"),
        executionID: UUID().uuidString, results: ActionReportStore())
    let counter = CompositionCounter()
    let definition = ActionFunction(
        path: input.call.actionPath, displayName: "Capture fixture", kind: .finite, completion: "Actual result",
        completing: { input in
            let preparation = try ActionComposition(
                .action("open", []) {
                    if fail { throw CameraControlError.permissionDenied }
                    return .completed
                })
            let value: String = try await preparation.run(
                returning: "capture", budget: .default, results: input.results
            ) {
                await counter.increment()
                return "media_151"
            }
            return .value(value)
        })
    let result = try await FunctionExecutor.perform(input, definition: definition)
    let report = try #require(await input.results.snapshot())
    #expect(await counter.count == (fail ? 0 : 1))
    if fail {
        guard case .report(let failure) = result else {
            Issue.record("Failure must retain report")
            return
        }
        #expect(failure.hasFailures)
        #expect(failure.entries.last?.code == .dependencyFailed)
    } else {
        #expect(result == .value("media_151"))
        #expect(report.entries.map(\.status) == [.succeeded, .succeeded])
    }
}
