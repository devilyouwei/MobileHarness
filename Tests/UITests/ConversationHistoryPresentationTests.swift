import Foundation
import Testing
import UI

@Test func historyTitlesUsePresentationFallbacksAndRawInput() throws {
    #expect(ConversationHistoryPresentation.title(try conversation()) == "新对话")
    #expect(ConversationHistoryPresentation.title(try conversation(user: "  original input  ")) == "  original input  ")
    #expect(ConversationHistoryPresentation.title(try conversation(archived: true)) == "待生成标题")
    #expect(ConversationHistoryPresentation.title(try conversation(archived: true, title: "Summary")) == "Summary")
}
private func conversation(archived: Bool = false, title: String? = nil, user: String? = nil) throws
    -> HistoryConversation
{
    var value: [String: Any] = ["id": UUID().uuidString, "createdAt": 0, "turns": []]
    if archived { value["archivedAt"] = 1 }
    if let title { value["summaryTitle"] = title }
    if let user {
        value["turns"] = [
            [
                "id": UUID().uuidString, "date": 0, "user": user, "request": [], "model": "fixture", "temperature": 0.7,
                "fragments": [], "state": "completed",
                "modelRequests": [
                    [
                        "id": UUID().uuidString, "date": 0, "input": user, "requestJSON": "[]",
                        "fragments": [], "toolCalls": [], "state": "completed",
                    ]
                ],
            ]
        ]
    }
    return try JSONDecoder().decode(HistoryConversation.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test @MainActor func conversationRetainsFinalizedUserCaptionAlongsideReplyUntilNextTurn() {
    let state = ConversationState()
    state.liveTranscript = "请一边跳舞一边做表情"
    state.finishUserTranscript()
    state.assistantReply = "好的，"
    state.assistantReply += "开始吧。"
    #expect(state.liveTranscript == "请一边跳舞一边做表情")
    #expect(state.transcriptFinalized)
    #expect(state.assistantReply == "好的，开始吧。")
    state.resetCaptions()
    #expect(state.liveTranscript.isEmpty && state.assistantReply.isEmpty)
    #expect(!state.transcriptFinalized)
    state.liveTranscript = "下一轮"
    #expect(state.liveTranscript == "下一轮")
}

@Test func historySeparatesModelRequestsAndPreservesNativeContextAndExport() throws {
    let callID = UUID().uuidString
    let firstID = UUID().uuidString
    let secondID = UUID().uuidString
    let native: [String: Any] = ["id": "provider-call", "name": "inspect", "argumentsJSON": "{}"]
    let context: [[String: Any]] = [
        ["role": "system", "content": "system"],
        ["role": "user", "content": "question"],
        ["role": "assistant", "content": "", "toolCalls": [native]],
        ["role": "tool", "content": "actual-result", "toolCallID": "provider-call"],
    ]
    let requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
    let rounds: [[String: Any]] = [
        [
            "id": firstID, "date": 10, "input": "question", "requestJSON": "[]", "fragments": [],
            "toolCalls": [
                [
                    "id": callID, "providerID": "provider-call", "name": "inspect", "argumentsJSON": "{}",
                    "state": "completed", "output": "actual-result",
                ]
            ], "state": "completed", "finishReason": "toolCalls",
        ],
        [
            "id": secondID, "date": 20, "input": "[tool]\nactual-result", "requestJSON": requestJSON,
            "firstTokenAt": 20.125, "modelRequestStartedAt": 20.1, "firstTokenLatency": 0.025,
            "fragments": ["observed"], "toolCalls": [], "state": "completed",
            "finishReason": "stop",
            "tokenUsage": ["input": 4, "generated": 2, "total": 6],
        ],
    ]
    let conversation = try historyFixture(extra: ["modelRequests": rounds, "toolDefinitions": ["definition"]])
    let rows = ConversationHistoryPresentation.turns(conversation)
    #expect(rows.count == 2 && rows.map(\.id.uuidString) == [firstID, secondID])
    #expect(rows[0].user == "question" && rows[0].isReACT == false)
    #expect(rows[0].raw.isEmpty && rows[0].outputSummary == "Tool Call：inspect")
    #expect(rows[0].firstTokenReport == "首 token 耗时：")
    #expect(rows[1].user == "[tool]\nactual-result" && rows[1].isReACT == true)
    #expect(rows[1].raw == "observed" && rows[1].toolCalls?.isEmpty == true)
    #expect(rows[1].request.last?.role == .tool && rows[1].request.last?.toolCallID == "provider-call")
    #expect(rows[1].request[2].toolCalls?.first?.name == "inspect")
    #expect(rows[1].firstTokenReport == "首 token 耗时：0.025 秒")
    #expect(rows[1].toolDefinitions == ["definition"])
    #expect(rows[1].diagnosticReport().contains(requestJSON))
    #expect(rows[1].diagnosticReport().contains("CURRENT INPUT\n[tool]\nactual-result"))
    #expect(rows[0].diagnosticReport().contains("Output: actual-result"))
}

@Test func historyKeepsSentDefinitionsEvenWithoutCallsAndMalformedRequestIsVisible() throws {
    let conversation = try historyFixture(extra: [
        "toolDefinitions": ["unused tool"],
        "modelRequests": [
            [
                "id": UUID().uuidString, "date": 0, "input": "question", "requestJSON": "invalid JSON",
                "fragments": [], "toolCalls": [], "state": "completed",
            ]
        ],
    ])
    let rows = ConversationHistoryPresentation.turns(conversation)
    #expect(rows.count == 1 && rows[0].toolCalls?.isEmpty == true && rows[0].toolDefinitions == ["unused tool"])
    #expect(rows[0].requestJSON == "invalid JSON" && rows[0].request.isEmpty)
    #expect(rows[0].diagnosticReport().contains("invalid JSON"))
}

@Test func historyDoesNotSynthesizeRequestsFromInputAggregate() throws {
    let conversation = try historyFixture(extra: ["modelRequests": [], "fragments": ["aggregate"]])
    #expect(ConversationHistoryPresentation.turns(conversation).isEmpty)
}

private func historyFixture(extra: [String: Any]) throws -> HistoryConversation {
    var turn: [String: Any] = [
        "id": UUID().uuidString, "date": 0, "user": "question", "request": [], "model": "fixture", "temperature": 0.7,
        "fragments": [], "state": "completed",
    ]
    turn.merge(extra) { _, new in new }
    let value: [String: Any] = ["id": UUID().uuidString, "createdAt": 0, "turns": [turn]]
    return try JSONDecoder().decode(HistoryConversation.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func historyImageReferencesUseOnlyStructuredMetadataWithoutEmbeddingBytes() throws {
    let image = HistoryImageReference(id: UUID(), mimeType: "image/jpeg", byteCount: 8)
    let marker = "\nImage attachments (bytes omitted): \(image.id.uuidString) image/jpeg 8 bytes"
    let textOnly = HistoryMessage(role: .user, content: "photo" + marker)
    #expect(textOnly.attachedImages.isEmpty && textOnly.displayContent == "photo" + marker)
    let structured = HistoryMessage(role: .user, content: "actual input", imageReferences: [image])
    #expect(structured.attachedImages == [image] && structured.displayContent == "actual input")
    #expect(
        HistoryMessage(role: .assistant, content: "photo" + marker, imageReferences: [image]).attachedImages.isEmpty)
    let messages = String(decoding: try JSONEncoder().encode([textOnly, structured]), as: UTF8.self)
    let turn = try historyFixture(extra: [
        "request": try JSONSerialization.jsonObject(with: Data(messages.utf8)), "user": "photo" + marker,
    ])
    let row = try #require(turn.turns.first)
    #expect(row.attachedImages == [image] && row.displayInput == "photo" + marker)
    #expect(row.request.first?.content.contains("bytes omitted") == true)
}

@Test func historyImageReferencesRejectInvalidMetadataAndBoundTheGallery() {
    let valid = (0..<6).map { _ in HistoryImageReference(id: UUID(), mimeType: "image/png", byteCount: 1) }
    #expect(HistoryMessage(role: .user, content: "", imageReferences: valid).attachedImages.count == 4)
    let invalid = [
        HistoryImageReference(id: UUID(), mimeType: "text/plain", byteCount: 1),
        HistoryImageReference(id: UUID(), mimeType: "image/jpeg", byteCount: 0),
        HistoryImageReference(id: UUID(), mimeType: "image/png", byteCount: 4 * 1024 * 1024 + 1),
    ]
    #expect(HistoryMessage(role: .user, content: "", imageReferences: invalid).attachedImages.isEmpty)
    #expect(
        HistoryMessage(role: .user, content: "\nImage attachments (bytes omitted): invalid image/png 1 bytes")
            .attachedImages.isEmpty)
}

@Test func taskHistoryFiltersOriginalInputBeforeExpandingRequests() throws {
    let value = try conversation(user: "task input")
    let id = try #require(value.turns.first?.id)
    #expect(ConversationHistoryPresentation.turns(value, inputIDs: [id]).count == 1)
    #expect(ConversationHistoryPresentation.turns(value, inputIDs: [UUID()]).isEmpty)
    #expect(ConversationHistoryPresentation.turns(value).count == 1)
}

@Test func missingProviderTimingDoesNotInventInterfaceLatency() throws {
    let id = UUID().uuidString
    let conversation = try historyFixture(extra: [
        "modelRequests": [
            [
                "id": id, "date": 20, "input": "hello", "requestJSON": "[]", "firstTokenAt": 23,
                "fragments": ["reply"], "toolCalls": [], "state": "completed",
            ]
        ]
    ])
    let row = try #require(ConversationHistoryPresentation.turns(conversation).first)
    #expect(row.firstTokenReport == "首 token 耗时：")
    #expect(!row.firstTokenReport.contains("3.000"))
}
