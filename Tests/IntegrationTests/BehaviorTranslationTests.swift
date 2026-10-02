import ActionRuntime
import Actions
import AgentCore
import Foundation
import Testing
import ToolRuntime
import Tools

@testable import Gateway

@Test func behaviorTranslationPreservesCorrelationWithoutAgentObjectsInExecution() throws {
    let turn = ConversationTurn(ordinal: 9)
    let input = AgentInput(sessionID: UUID(), payload: .event("boundary"), turn: turn)
    let owner = ExecutionOwner(agent: .assistant, incarnation: UUID(), sessionID: input.sessionID)
    let call = ActionCall(
        actionPath: .init(module: "Fixture", function: "move"), channel: "Robot", parameters: ["target": "2048"])
    let envelope = OutputEnvelope(source: .assistant, input: input, output: .actionCall(call), sequence: 42)
    let scheduled = try ScheduledAction(envelope: envelope, owner: owner, feedback: .terminal)
    let execution = scheduled.execution
    #expect(execution.executionID == scheduled.executionID)
    #expect(execution.context.source == "assistant")
    #expect(execution.context.inputID == input.id)
    #expect(execution.context.sessionID == input.sessionID)
    #expect(execution.context.correlationID == turn.id)
    #expect(execution.context.ordinal == 9 && execution.context.sequence == 42)
    #expect(execution.call.parameters == call.parameters)
    #expect(envelope.toolContext.correlationID == turn.id)
    #expect(envelope.toolContext.inputID == input.id)
}

@Test func behaviorResultTranslationPreservesChildDetailsAndExecutionFailure() throws {
    let report = try ActionReport(entries: [
        .init(path: "root.first", status: .succeeded, motor: 4, target: 1238, observed: 1240),
        .init(path: "root.second", status: .failed, code: .targetNotReached, motor: 3, target: 2048, observed: 1950),
        .init(path: "root.third", status: .notStarted, code: .cancelled, motor: 5),
    ]).withExecutionFailure(.timedOut)
    guard case .report(let delivered) = ActionCompletion.report(report).agentValue else {
        Issue.record("Translation lost report")
        return
    }
    #expect(delivered.executionFailure == .timedOut)
    #expect(delivered.status == .partialFailure)
    #expect(delivered.entries.count == report.entries.count)
    for (actual, expected) in zip(delivered.entries, report.entries) {
        #expect(actual.path == expected.path)
        #expect(actual.status.rawValue == expected.status.rawValue)
        #expect(actual.code?.rawValue == expected.code?.rawValue)
        #expect(actual.motor == expected.motor)
        #expect(actual.target == expected.target && actual.observed == expected.observed)
    }
}
