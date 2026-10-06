import Actions
import AgentCore
import Agents
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Testing

/// Reuse scheduler fixtures in argument validation tests while constructing a genuine immediate Tool envelope.
func uiActionInvocation(_ invocation: any FunctionInput) -> ActionInvocation {
    let call = ToolCall(
        toolPath: "Fixture.Control.UI." + invocation.call.actionPath.function, arguments: invocation.call.parameters)
    let e = invocation.testEnvelope
    let envelope = OutputEnvelope(
        source: e.source,
        input: AgentInput(id: e.inputID, sessionID: e.sessionID, payload: .event("fixture"), turn: e.turn),
        output: .toolCall(call), sequence: e.sequence)
    return ActionInvocation(call: call, envelope: envelope)
}

private actor CaptionEndpoint {
    var policy = ConversationPresentation()
    var reply = ""
    var transcript = ""
    func begin(_ invocation: any FunctionInput) {
        if policy.accept(invocation.context, update: .beginReply) { reply = "" }
    }
    func append(_ text: String, _ invocation: any FunctionInput) {
        if policy.accept(invocation.context, update: .reply) { reply += text }
    }
    func replace(_ text: String, _ invocation: any FunctionInput) {
        if policy.accept(invocation.context, update: .transcript) { transcript = text }
    }
    func close(_ invocation: any FunctionInput) {
        if policy.accept(invocation.context, update: .finishTranscript) { transcript = "" }
    }
}

@Test func immediateCaptionToolsPreserveAppendReplacementAndTurnFences() async throws {
    let endpoint = CaptionEndpoint()
    let input = AgentInput(sessionID: UUID(), payload: .event("fixture"), turn: AgentTurn(ordinal: 1))
    func invocation(_ function: String, text: String? = nil, source: AgentID, sequence: UInt64) -> ActionInvocation {
        let call = ToolCall(toolPath: "Fixture.Control.UI." + function, arguments: text.map { ["text": $0] } ?? [:])
        return ActionInvocation(
            call: call,
            envelope: OutputEnvelope(
                source: source, input: input,
                output: .toolCall(call), sequence: sequence))
    }
    try await UIActions.beginReplyTurn(invocation: invocation("beginReplyTurn", source: .assistant, sequence: 1)) {
        await endpoint.begin($0)
    }
    let first = invocation("print", text: "第一句。", source: .assistant, sequence: 2)
    for _ in 0..<2 {
        try await UIActions.print(invocation: first) { await endpoint.append($0, $1) }
    }
    try await UIActions.print(invocation: invocation("print", text: "第二句。", source: .assistant, sequence: 3)) {
        await endpoint.append($0, $1)
    }
    #expect(await endpoint.reply == "第一句。第二句。")
    for (offset, text) in ["你", "你好", "你好世界"].enumerated() {
        try await UIActions.setTranscript(
            invocation: invocation(
                "setTranscript", text: text,
                source: .speechPerception, sequence: UInt64(offset + 1))
        ) { await endpoint.replace($0, $1) }
    }
    #expect(await endpoint.transcript == "你好世界")
    try await UIActions.finishTranscript(
        invocation: invocation("finishTranscript", source: .speechPerception, sequence: 4)
    ) {
        await endpoint.close($0)
    }
    try await UIActions.setTranscript(
        invocation: invocation(
            "setTranscript", text: "迟到的结果",
            source: .speechPerception, sequence: 5)
    ) { await endpoint.replace($0, $1) }
    #expect(await endpoint.transcript.isEmpty)
    #expect(await endpoint.reply == "第一句。第二句。")
}
