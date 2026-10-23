import Actions
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import StorageCore
import Testing

@testable import Gateway

@Test(.actionCatalog) func behaviorTranslationPreservesCorrelationWithoutAgentObjectsInExecution() throws {
    let turn = AgentTurn(id: UUID().uuidString, ordinal: 9)
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("boundary"),
        turn: turn)
    let owner = ExecutionOwner(agent: .assistant, incarnation: UUID().uuidString, sessionID: input.sessionID)
    let call = ActionCall(
        actionPath: .init(domain: "Fixture", module: "Control", function: "move"), channel: "Robot",
        parameters: ["target": "2048"])
    let envelope = OutputEnvelope(
        source: .assistant, context: input.context, output: .actionCall(call), sequence: 42, taskScope: input.taskScope)
    let scheduled = try ScheduledAction(envelope: envelope, owner: owner, feedback: .terminal)
    let execution = scheduled.execution
    #expect(execution.executionID == scheduled.executionID)
    #expect(execution.context.source == "assistant")
    #expect(execution.context.inputID == input.id)
    #expect(execution.context.sessionID == input.sessionID)
    #expect(execution.context.correlationID == turn.id)
    #expect(execution.context.ordinal == 9 && execution.context.sequence == 42)
    #expect(execution.call.parameters == call.parameters)
    #expect(envelope.executionContext.correlationID == turn.id)
    #expect(envelope.executionContext.inputID == input.id)
}

@Test(.actionCatalog) func behaviorResultTranslationPreservesChildDetailsAndExecutionFailure() throws {
    let report = try ActionReport(entries: [
        .init(path: "root.first", status: .succeeded, details: ["motor": "4", "target": "1238", "observed": "1240"]),
        .init(
            path: "root.second", status: .failed, code: .targetNotReached,
            details: ["motor": "3", "target": "2048", "observed": "1950"]),
        .init(path: "root.third", status: .notStarted, code: .cancelled, details: ["motor": "5"]),
    ]).withExecutionFailure(.timedOut)
    guard case .report(let delivered) = ActionCompletion.report(report).agentValue else {
        Issue.record("Translation lost report")
        return
    }
    #expect(delivered.executionFailure?.rawValue == "timedOut")
    #expect(delivered.status == .partialFailure)
    #expect(delivered.entries.count == report.entries.count)
    for (actual, expected) in zip(delivered.entries, report.entries) {
        #expect(actual.path == expected.path)
        #expect(actual.status.rawValue == expected.status.rawValue)
        #expect(actual.code?.rawValue == expected.code?.rawValue)
        #expect(actual.details == expected.details)
    }
}

@Test(.actionCatalog) func genericAgentReportRetainsOpaqueProviderDetailsAndCancellation() throws {
    let report = try AgentActionReport(entries: [
        .init(
            path: "Fixture.Control.fixture", status: .failed, code: .init(rawValue: "fixture.sensorUnavailable"),
            details: ["sensor": "depth", "expected": "ready", "actual": "offline"])
    ])
    #expect(report.entries[0].code?.rawValue == "fixture.sensorUnavailable")
    #expect(report.entries[0].details["sensor"] == "depth")
    #expect(report.status == .failed)
    let successful = try AgentActionReport(entries: [.init(path: "Fixture.Control.fixture", status: .succeeded)])
    #expect(successful.withExecutionFailure(.cancelled).status == .cancelled)
}

@Test(.actionCatalog) func actionFailureTranslationPreservesProducerIdentifiers() {
    let failures: [ActionFailure] = [
        .operationFailed, .resourceUnavailable, .invalidArguments,
        .init(rawValue: "fixture.customFailure"), .init(rawValue: "feedbackTimeout"),
    ]
    for failure in failures {
        #expect(failure.observationFailure.rawValue == failure.rawValue)
    }
}

@Test(.actionCatalog) func runtimeTransportsProducerReportCodeWithoutInterpretingFailureIdentity() {
    struct FixtureError: ActionReportFailureProviding {
        let actionExecutionFailure = ActionFailure(rawValue: "feedbackTimeout")
        let actionReportCode = ActionReport.Entry.Code(rawValue: "fixture.customOutcome")
    }
    #expect(ActionReport.code(for: FixtureError()).rawValue == "fixture.customOutcome")
    #expect(ActionReport.code(for: CancellationError()) == .cancelled)
}
