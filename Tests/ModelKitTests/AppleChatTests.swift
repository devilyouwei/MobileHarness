import Foundation
import FoundationModels
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitAppleLLM

@available(iOS 27, macOS 27, *)
@Test func appleChatPublishesTextOnlyCapabilityAndRejectsBeforeInference() async throws {
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 1)
    let model: any ChatCapability = try AppleChat(context: context)
    #expect(await model.supportsToolCalls == false)
    #expect(await model.supportsImages == false)
    let request = try ChatRequest(messages: [.init(role: .user, content: " ")])
    await #expect(throws: CapabilityError.invalidRequest("Apple chat requires a nonempty final user message")) {
        _ = try await model.chat(request)
    }
    await context.shutdown()
}

@available(iOS 27, macOS 27, *)
@Test func appleChatPreservesNativeHistoryAndCurrentPrompt() throws {
    let input = try AppleChatInput(
        ChatRequest(messages: [
            .init(role: .system, content: "Instruction"),
            .init(role: .user, content: "First"),
            .init(role: .assistant, content: "Answer"),
            .init(role: .user, content: "Second"),
        ]))
    #expect(input.prompt == "Second")
    #expect(input.transcript.count == 3)
    guard case .instructions(let instructions) = input.transcript[0],
        case .prompt(let prompt) = input.transcript[1],
        case .response(let response) = input.transcript[2]
    else {
        Issue.record("Native roles were not preserved")
        return
    }
    #expect(instructions.segments == [.text(.init(id: instructions.segments[0].id, content: "Instruction"))])
    #expect(prompt.segments.count == 1)
    guard case .text(let userText) = prompt.segments[0], case .text(let assistantText) = response.segments[0] else {
        Issue.record("Expected native text segments")
        return
    }
    #expect(userText.content == "First")
    #expect(assistantText.content == "Answer")
}

@available(iOS 27, macOS 27, *)
@Test func appleChatRejectsUnsupportedAndInvalidInputs() throws {
    let tool = try ChatToolDefinition(
        declaration: Data(
            #"{"type":"function","function":{"name":"lookup","parameters":{"type":"object"}}}"#.utf8))
    let call = ChatToolCall(id: "call", name: "lookup", argumentsJSON: "{}")
    let requests = try [
        ChatRequest(messages: [.init(role: .user, content: "Hi")], tools: [tool]),
        ChatRequest(
            messages: [.init(role: .user, content: "Hi")], tools: [tool], toolChoice: .required(name: "lookup")),
        ChatRequest(messages: [
            .init(role: .user, content: "Hi", images: [ChatImage(id: "image", data: Data([1]))])
        ]),
        ChatRequest(messages: [.init(role: .user, content: "Old"), .init(role: .user, content: " \n")]),
        ChatRequest(messages: [.init(role: .assistant, content: "Answer"), .init(role: .user, content: "Hi")]),
        ChatRequest(messages: [.init(role: .user, content: "Hi"), .init(role: .assistant, content: "Answer")]),
        ChatRequest(messages: [
            .init(role: .user, content: "Hi"), .init(role: .system, content: "Late"), .init(role: .user, content: "Hi"),
        ]),
        ChatRequest(messages: [
            .init(role: .assistant, content: "", toolCalls: [call]),
            .init(role: .tool, content: "result", toolCallID: "call"), .init(role: .user, content: "Hi"),
        ]),
    ]
    for request in requests {
        #expect(throws: CapabilityError.self) { try AppleChatInput(request) }
    }
}

@Test func appleChatConvertsCumulativeUnicodeWithoutRepeatingOutput() throws {
    var output = AppleChatText()
    #expect(try output.append("a") == ["a"])
    #expect(try output.append("a") == [])
    #expect(try output.append("a\u{301}你好") == ["\u{301}你好"])
    let snapshot = output.text + String(repeating: "😀", count: 3000)
    let chunks = try output.append(snapshot)
    #expect(chunks.joined() == String(repeating: "😀", count: 3000))
    #expect(chunks.allSatisfy { $0.utf8.count <= 4096 })
    #expect(throws: CapabilityError.self) { try output.append("revised") }
    #expect(throws: CapabilityError.self) {
        try output.append(snapshot + String(repeating: "x", count: AppleChatText.maximumBytes))
    }
}
