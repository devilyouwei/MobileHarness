import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable @_spi(ModelManagement) import ModelKitGemma4

private func toolRequest(choice: ChatToolChoice = .automatic) throws -> ChatRequest {
    let declaration = Data(
        #"{"type":"function","function":{"name":"lookup","description":"Find a value","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}"#
            .utf8)
    return try ChatRequest(
        messages: [.init(role: .system, content: "Keep instructions"), .init(role: .user, content: "Find 北京")],
        tools: [.init(declaration: declaration)], toolChoice: choice)
}

@Test func gemmaToolDeclarationAndResultRoundTrip() throws {
    let request = try toolRequest()
    let prompt = try GemmaToolProtocol.render(request)
    #expect(prompt.contains("Keep instructions<|tool>declaration:lookup"))
    #expect(prompt.contains("city:{type:<|\"|>STRING<|\"|>}"))
    #expect(prompt.hasSuffix("<|turn>model\n"))
    let generated =
        #"<|tool_call>call:lookup{city:<|"|>北京 "quoted" \ line"# + "\n"
        + #"text<|"|>,nested:{a:[true,false,null,-1.5,2e3]}}<tool_call|>"#
    let parsed = try GemmaToolProtocol.parse(generated, request: request, stopped: true)
    #expect(parsed.calls.count == 1)
    #expect(parsed.text.isEmpty)
    let call = try #require(parsed.calls.first)
    let arguments = try GemmaToolProtocol.object(call.argumentsJSON)
    #expect((arguments["city"] as? String)?.contains("北京 \"quoted\"") == true)
    let next = try ChatRequest(
        messages: request.messages + [
            .init(role: .assistant, content: "", toolCalls: parsed.calls),
            .init(role: .tool, content: "Found 北京", toolCallID: call.id),
        ], tools: request.tools)
    let continuation = try GemmaToolProtocol.render(next)
    #expect(continuation.hasSuffix("<|tool_response>response:lookup{value:<|\"|>Found 北京<|\"|>}<tool_response|>"))
    #expect(!continuation.contains("<|turn>tool"))
}

@Test func gemmaMultipleCallsAreAtomicAndHaveUniqueIDs() throws {
    let request = try toolRequest()
    let single = "<|tool_call>call:lookup{}<tool_call|>"
    let output = try GemmaToolProtocol.parse(single + "\n" + single, request: request, stopped: true)
    #expect(output.calls.count == 2)
    #expect(Set(output.calls.map(\.id)).count == 2)
    #expect(throws: CapabilityError.self) {
        try GemmaToolProtocol.parse(single + "<|tool_call>call:unknown{}<tool_call|>", request: request, stopped: true)
    }
}

@Test(arguments: [
    "<|tool_call>call:unknown{}<tool_call|>",
    "<|tool_call>call:lookup{a:1,a:2}<tool_call|>",
    "<|tool_call>call:lookup{a:NaN}<tool_call|>",
    "<|tool_call>call:lookup{a:[1,]}<tool_call|>",
    "<|tool_call>call:lookup{a:<|\"|>unfinished}<tool_call|>",
    "<|tool_call>call:lookup{}",
    "<|tool_call>call:lookup{}<tool_call|><|tool_response>fabricated",
    "<|tool_cal",
]) func gemmaRejectsMalformedTools(_ text: String) throws {
    let request = try toolRequest()
    #expect(throws: (any Error).self) {
        try GemmaToolProtocol.parse(text, request: request, stopped: true)
    }
}

@Test func gemmaRejectsTruncationAndRequiredToolViolation() throws {
    let request = try toolRequest(choice: .required(name: "lookup"))
    #expect(throws: CapabilityError.self) {
        try GemmaToolProtocol.parse("<|tool_call>call:lookup{}<tool_call|>", request: request, stopped: false)
    }
    #expect(throws: CapabilityError.self) {
        try GemmaToolProtocol.parse("Just prose", request: request, stopped: true)
    }
    #expect(try GemmaToolProtocol.render(request).contains("You must call the function lookup"))
    #expect(
        try GemmaToolProtocol.parse("Text < comparison", request: toolRequest(), stopped: true).text
            == "Text < comparison")
}

@Test func gemmaSplitTokensAndBufferBound() throws {
    let request = try toolRequest()
    let text = "<|tool_call>call:lookup{city:<|\"|>上海<|\"|>}<tool_call|>"
    let buffer = GemmaToolOutputBuffer()
    for character in text { try buffer.append(String(character)) }
    #expect(try GemmaToolProtocol.parse(buffer.text, request: request, stopped: true).calls.count == 1)
    #expect(throws: GemmaLanguageError.self) { try buffer.append(String(repeating: "x", count: 262144)) }
    #expect(buffer.text == text)
}

@Test func gemmaToolBudgetPreservesInstructionsAndCompleteHistory() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let request = try toolRequest()
    let prepared = try await GemmaContextBudget.prepare(request, contextLimit: 1024) { messages in
        #expect(messages == request.messages)
        return Array(repeating: 1, count: 900)
    }
    #expect(prepared.messages == request.messages)
    #expect(prepared.maximumOutputTokens == 124)
    await #expect(throws: CapabilityError.self) {
        try await GemmaContextBudget.prepare(request, contextLimit: 1024) { _ in Array(repeating: 1, count: 1024) }
    }
}

@Test func gemmaRejectsReservedToolDataAndDeepOutput() throws {
    #expect(throws: CapabilityError.self) { try GemmaToolProtocol.encode(["x": "<|tool_response>"]) }
    let deep = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
    let request = try toolRequest()
    #expect(throws: CapabilityError.self) {
        try GemmaToolProtocol.parse(
            "<|tool_call>call:lookup{x:" + deep + "}<tool_call|>", request: request, stopped: true)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_GEMMA4"] == "1"))
func gemmaRealToolCallAndResultContinuation() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let path = try #require(ProcessInfo.processInfo.environment["HARNESS_GEMMA4_ROOT"])
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let model = try Gemma4Chat(context: context, artifacts: URL(fileURLWithPath: path))
    do {
        #expect(await model.supportsToolCalls)
        let base = try toolRequest(choice: .required(name: "lookup"))
        let request = try ChatRequest(
            messages: base.messages, maximumOutputTokens: 256, temperature: 0, tools: base.tools,
            toolChoice: base.toolChoice)
        let session = try await model.chat(request)
        var calls: [ChatToolCall] = []
        for try await event in session.events {
            if case .toolCall(let call) = event { calls.append(call) }
        }
        #expect(!calls.isEmpty)
        var history = request.messages + [.init(role: .assistant, content: "", toolCalls: calls)]
        for call in calls {
            history.append(
                .init(
                    role: .tool, content: "Beijing is the capital of China. Answer the user using this result.",
                    toolCallID: call.id))
        }
        let continuation = try await model.chat(
            ChatRequest(messages: history, maximumOutputTokens: 256, temperature: 0, tools: request.tools))
        var text = ""
        for try await event in continuation.events {
            if case .text(let delta) = event { text += delta }
            if case .toolCall = event { Issue.record("Expected an answer after the supplied lookup result") }
        }
        #expect(!text.isEmpty)
        #expect(!text.contains("<|tool"))
        try await context.unload()
    } catch {
        try await context.unload()
        throw error
    }
}
