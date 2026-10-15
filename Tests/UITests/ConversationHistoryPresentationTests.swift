import Foundation
import Testing
import UI

@Test func historyRefreshInvalidatesPreviousPagingTickets() throws {
    var state = HistoryPageLoading<UInt64>()
    let first = state.begin(after: 50)
    let old = try #require(first)
    state = .init()
    let second = state.begin(after: 50)
    let fresh = try #require(second)
    state.finish(old, error: "stale read")
    state.cancel(old)
    #expect(state.accepts(fresh) && state.isLoading && state.error == nil)
    state.finish(fresh)
    #expect(!state.isLoading && state.error == nil)
}

@Test func historyPagingDeduplicatesCursorAndRequiresExplicitFailureRetry() throws {
    var loading = HistoryPageLoading<UInt64>()
    let initialAttempt = loading.begin(after: 50)
    let first = try #require(initialAttempt)
    let overlap = loading.begin(after: 50)
    let otherOverlap = loading.begin(after: 100, retry: true)
    #expect(loading.isLoading && overlap == nil && otherOverlap == nil)
    loading.finish(first, error: "actual failure")
    #expect(!loading.isLoading && loading.error == "actual failure")
    let automaticRetry = loading.begin(after: 50)
    #expect(automaticRetry == nil)
    let retryAttempt = loading.begin(after: 50, retry: true)
    let retry = try #require(retryAttempt)
    #expect(loading.error == nil && loading.isLoading)
    loading.finish(retry)
    let repeatedCursor = loading.begin(after: 50)
    let nextCursor = loading.begin(after: 100)
    #expect(repeatedCursor == nil && nextCursor != nil)
}

@Test func historyPagingCancellationAllowsReentryAndRejectsOldTickets() throws {
    var loading = HistoryPageLoading<String>()
    let original = loading.begin(after: "dialog_50")
    let cancelled = try #require(original)
    #expect(loading.completionID == nil)
    loading.cancel(cancelled)
    let completed = try #require(loading.completionID)
    let next = loading.begin(after: "dialog_50")
    let replacement = try #require(next)
    loading.finish(cancelled, error: "late failure")
    loading.cancel(cancelled)
    #expect(loading.accepts(replacement) && loading.error == nil && loading.isLoading)
    #expect(loading.completionID == completed)
    loading.finish(replacement)
    #expect(!loading.isLoading && loading.error == nil && loading.completionID != completed)
}

private func taskPreviewPage(
    dialog: String = "dialog_1", request: String = "round_1", input: String = "input_1",
    sourceInput: String = "input_1", sourceRequest: String = "round_1", task: Bool = true,
    state: String = "completed", taskState: String = "completed"
) throws -> HistoryConversation {
    var invocation: [String: Any] = [
        "id": request, "historyOrder": request == "round_2" ? 3 : (task ? 2 : 1), "date": 0,
        "input": "actual input", "requestJSON": "[]",
        "response": "actual response", "toolCalls": [], "state": state,
    ]
    if task { invocation["historyTaskID"] = "task_1" }
    let value: [String: Any] = [
        "id": dialog, "createdAt": 0,
        "turns": [
            [
                "id": input, "date": 0, "user": "actual input", "request": [], "model": "fixture", "temperature": 0.7,
                "modelRequests": [invocation], "response": "", "state": state,
            ]
        ],
        "taskCompressions": task
            ? [
                [
                    "taskID": "task_1", "goal": "actual Task", "status": taskState, "reportedSummary": "done",
                    "completedAt": 1,
                    "sources": [
                        ["inputID": sourceInput, "requestID": sourceRequest],
                        ["inputID": "input_2", "requestID": "round_2"],
                    ],
                ]
            ] : [],
    ]
    return try JSONDecoder().decode(HistoryConversation.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func historyFoldsTheLoadedSubsetOfAnEntireTask() throws {
    let page = try taskPreviewPage()
    let items = ConversationHistoryPresentation.timeline(page)
    guard case .task(let task, let visible) = try #require(items.first) else {
        Issue.record("A single loaded preview must represent the complete expandable Task")
        return
    }
    #expect(items.count == 1 && task.sources.count == 2 && visible.count == 1)
    #expect(task.reportedSummary == "done" && visible[0].response == "actual response")
    let exported = try JSONDecoder().decode(
        HistoryConversation.self, from: ConversationHistoryPresentation.jsonData(page))
    #expect(exported.taskCompressions[0].sources == task.sources)
}

@Test(arguments: ["wrong-input", "wrong-request", "generating-request", "generating-task"])
func historyDoesNotFoldMismatchedOrUnfinishedTaskPreviews(_ invalid: String) throws {
    let page = try taskPreviewPage(
        sourceInput: invalid == "wrong-input" ? "other-input" : "input_1",
        sourceRequest: invalid == "wrong-request" ? "other-request" : "round_1",
        state: invalid == "generating-request" ? "generating" : "completed",
        taskState: invalid == "generating-task" ? "generating" : "completed")
    guard case .request = try #require(ConversationHistoryPresentation.timeline(page).first) else {
        Issue.record("Invalid membership or unfinished work must remain an ordinary request")
        return
    }
}

@Test func historyAppendsTaskMetadataFromLaterPagesAndRejectsForeignDialogs() throws {
    var loaded = try taskPreviewPage(request: "ordinary", input: "ordinary-input", task: false)
    loaded.nextPosition = 50
    let taskPage = try taskPreviewPage()
    try loaded.appendPage(taskPage)
    #expect(loaded.turns.count == 2 && loaded.taskCompressions.count == 1 && loaded.nextPosition == nil)
    let items = ConversationHistoryPresentation.timeline(loaded)
    guard case .task(let task, _) = try #require(items.last) else {
        Issue.record("Task summaries first encountered after page one must render")
        return
    }
    #expect(items.count == 2 && task.sources.count == 2)
    var expansion = taskPage
    try expansion.appendPage(try taskPreviewPage(request: "round_2", input: "input_2"))
    #expect(expansion.taskCompressions.count == 1)
    #expect(ConversationHistoryPresentation.turns(expansion).map(\.id) == ["round_1", "round_2"])
    #expect(throws: HistoryDetailError.unavailable) { try loaded.appendPage(taskPreviewPage(dialog: "dialog_2")) }
    #expect(loaded.turns.count == 2 && loaded.taskCompressions.count == 1)
}

@Test func historyTitlesUsePresentationFallbacksAndRawInput() throws {
    #expect(ConversationHistoryPresentation.title(try conversation()) == "新对话")
    #expect(ConversationHistoryPresentation.title(try conversation(user: "  original input  ")) == "  original input  ")
    #expect(ConversationHistoryPresentation.title(try conversation(archived: true)) == "待生成标题")
    #expect(ConversationHistoryPresentation.title(try conversation(archived: true, title: "Summary")) == "Summary")
}
private func conversation(archived: Bool = false, title: String? = nil, user: String? = nil) throws
    -> HistoryConversation
{
    var value: [String: Any] = [
        "historyOrder": 1, "id": UUID().uuidString, "createdAt": 0, "taskCompressions": [],
        "turns": [],
    ]
    if archived { value["archivedAt"] = 1 }
    if let title { value["summaryTitle"] = title }
    if let user {
        value["turns"] = [
            [
                "historyOrder": 1, "id": UUID().uuidString, "date": 0, "user": user, "request": [],
                "model": "fixture",
                "temperature": 0.7,
                "response": "", "state": "completed",
                "modelRequests": [
                    [
                        "historyOrder": 1, "id": UUID().uuidString, "date": 0, "input": user,
                        "requestJSON": "[]",
                        "response": "", "toolCalls": [], "state": "completed",
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
    let native: [String: Any] = ["historyOrder": 1, "id": "provider-call", "name": "inspect", "argumentsJSON": "{}"]
    let context: [[String: Any]] = [
        ["role": "system", "content": "system"],
        ["role": "user", "content": "question"],
        ["role": "assistant", "content": "", "toolCalls": [native]],
        ["role": "tool", "content": "actual-result", "toolCallID": "provider-call"],
    ]
    let requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
    let rounds: [[String: Any]] = [
        [
            "historyOrder": 1, "id": firstID, "date": 10, "input": "question", "requestJSON": "[]", "response": "",
            "toolCalls": [
                [
                    "historyOrder": 1, "id": callID, "providerID": "provider-call", "name": "inspect",
                    "argumentsJSON": "{}",
                    "state": "completed", "output": "actual-result",
                ]
            ], "state": "completed", "finishReason": "toolCalls",
        ],
        [
            "historyOrder": 2, "id": secondID, "date": 20, "input": "[tool]\nactual-result", "requestJSON": requestJSON,
            "firstTokenAt": 20.125, "modelRequestStartedAt": 20.1, "firstTokenLatency": 0.025,
            "response": "observed", "toolCalls": [], "state": "completed",
            "finishReason": "stop",
            "tokenUsage": ["input": 4, "generated": 2, "total": 6],
        ],
    ]
    let conversation = try historyFixture(extra: ["modelRequests": rounds, "toolDefinitions": ["definition"]])
    let rows = ConversationHistoryPresentation.turns(conversation)
    #expect(rows.count == 2 && rows.map(\.id) == [firstID, secondID])
    #expect(rows[0].user == "question" && rows[0].isReACT == false)
    #expect(rows[0].raw.isEmpty && rows[0].outputSummary == "Tool Call：inspect")
    #expect(rows[0].firstTokenReport == "首 token 耗时：")
    #expect(rows[1].user == "[tool]\nactual-result" && rows[1].isReACT == true)
    #expect(rows[1].raw == "observed" && rows[1].toolCalls?.isEmpty == true)
    #expect(rows[1].request.last?.role == .tool && rows[1].request.last?.toolCallID == "provider-call")
    #expect(rows[1].request[2].toolCalls?.first?.name == "inspect")
    #expect(rows[1].firstTokenReport == "首 token 耗时：0.025 秒")
    #expect(rows[1].toolDefinitions == ["definition"])
    let secondExport = try JSONDecoder().decode(
        HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(rows[1]))
    #expect(secondExport.requestJSON == requestJSON && secondExport.user == "[tool]\nactual-result")
    #expect(secondExport.raw == "observed" && secondExport.request.last?.toolCallID == "provider-call")
    let firstExport = try JSONDecoder().decode(
        HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(rows[0]))
    #expect(firstExport.toolCalls?.first?.output == "actual-result")
}

@Test func historyKeepsSentDefinitionsEvenWithoutCallsAndMalformedRequestIsVisible() throws {
    let conversation = try historyFixture(extra: [
        "toolDefinitions": ["unused tool"],
        "modelRequests": [
            [
                "historyOrder": 1, "id": UUID().uuidString, "date": 0, "input": "question",
                "requestJSON": "invalid JSON",
                "response": "", "toolCalls": [], "state": "completed",
            ]
        ],
    ])
    let rows = ConversationHistoryPresentation.turns(conversation)
    #expect(rows.count == 1 && rows[0].toolCalls?.isEmpty == true && rows[0].toolDefinitions == ["unused tool"])
    #expect(rows[0].requestJSON == "invalid JSON" && rows[0].request.isEmpty)
    let exported = try JSONDecoder().decode(HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(rows[0]))
    #expect(exported.requestJSON == "invalid JSON" && exported.request.isEmpty)
}

@Test func historyDoesNotSynthesizeRequestsFromInputAggregate() throws {
    let conversation = try historyFixture(extra: ["modelRequests": [], "response": "aggregate"])
    #expect(ConversationHistoryPresentation.turns(conversation).isEmpty)
}

private func historyFixture(extra: [String: Any]) throws -> HistoryConversation {
    var turn: [String: Any] = [
        "historyOrder": 1, "id": UUID().uuidString, "date": 0, "user": "question", "request": [],
        "model": "fixture",
        "temperature": 0.7,
        "response": "", "state": "completed",
    ]
    turn.merge(extra) { _, new in new }
    let value: [String: Any] = [
        "historyOrder": 1, "id": UUID().uuidString, "createdAt": 0, "taskCompressions": [],
        "turns": [turn],
    ]
    return try JSONDecoder().decode(HistoryConversation.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func historyImageReferencesUseOnlyStructuredMetadataWithoutEmbeddingBytes() throws {
    let image = HistoryImageReference(id: UUID().uuidString, mimeType: "image/jpeg", byteCount: 8)
    let marker = "\nImage attachments (bytes omitted): \(image.id) image/jpeg 8 bytes"
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
    let valid = (0..<6).map { _ in
        HistoryImageReference(id: UUID().uuidString, mimeType: "image/png", byteCount: 1)
    }
    #expect(HistoryMessage(role: .user, content: "", imageReferences: valid).attachedImages.count == 4)
    let invalid = [
        HistoryImageReference(id: UUID().uuidString, mimeType: "text/plain", byteCount: 1),
        HistoryImageReference(id: UUID().uuidString, mimeType: "image/jpeg", byteCount: 0),
        HistoryImageReference(id: UUID().uuidString, mimeType: "image/png", byteCount: 4 * 1024 * 1024 + 1),
    ]
    #expect(HistoryMessage(role: .user, content: "", imageReferences: invalid).attachedImages.isEmpty)
    #expect(
        HistoryMessage(role: .user, content: "\nImage attachments (bytes omitted): invalid image/png 1 bytes")
            .attachedImages.isEmpty)
}

@Test func historyRequestNavigationIgnoresExtraTapsUntilSingleDestinationDismisses() throws {
    let first = try #require(ConversationHistoryPresentation.turns(try conversation(user: "first")).first)
    let second = try #require(ConversationHistoryPresentation.turns(try conversation(user: "second")).first)
    var navigation = HistoryRequestNavigation()
    #expect(!navigation.isPresented && navigation.turn == nil)
    navigation.open(first)
    navigation.open(first)
    navigation.open(second)
    #expect(navigation.isPresented && navigation.turn?.id == first.id)
    // Native Back and an interactive pop both write this one presentation flag.
    navigation.isPresented = false
    #expect(!navigation.isPresented)
    navigation.open(first)
    #expect(navigation.isPresented && navigation.turn?.id == first.id)
    navigation.isPresented = false
    navigation.open(second)
    #expect(navigation.isPresented && navigation.turn?.id == second.id)
}

@Test func missingProviderTimingDoesNotInventInterfaceLatency() throws {
    let id = UUID().uuidString
    let conversation = try historyFixture(extra: [
        "modelRequests": [
            [
                "historyOrder": 1, "id": id, "date": 20, "input": "hello", "requestJSON": "[]", "firstTokenAt": 23,
                "response": "reply", "toolCalls": [], "state": "completed",
            ]
        ]
    ])
    let row = try #require(ConversationHistoryPresentation.turns(conversation).first)
    #expect(row.firstTokenReport == "首 token 耗时：")
    #expect(!row.firstTokenReport.contains("3.000"))
}

@Test func historyJSONExportRoundTripsFullConversation() throws {
    let original = try conversation(user: "原始输入\n\"quoted\" / path")
    let data = try ConversationHistoryPresentation.jsonData(original)
    let exported = try JSONDecoder().decode(HistoryConversation.self, from: data)
    #expect(exported.id == original.id && exported.turns.count == original.turns.count)
    #expect(exported.turns.first?.user == original.turns.first?.user)
    #expect(exported.turns.first?.modelRequests?.first?.input == original.turns.first?.modelRequests?.first?.input)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["turns"] != nil && object["taskCompressions"] != nil)
    #expect(object["interpretation"] == nil && object["diagnosticReport"] == nil)
}

@Test func historyJSONExportRejectsOversizeAndInvalidNumericValues() throws {
    let value = try conversation(user: "actual record")
    #expect(throws: HistoryJSONExportError.self) {
        try ConversationHistoryPresentation.jsonData(value, maximumBytes: 1)
    }
    #expect(throws: EncodingError.self) {
        try ConversationHistoryPresentation.jsonData(["temperature": Double.nan])
    }
}

@Test func historyTaskReferencesMergeMatchingIDsWithoutChangingExport() throws {
    let id = UUID().uuidString
    let turn = try taskReferenceFixture(owner: id, snapshot: id)
    let references = ConversationHistoryPresentation.taskReferences(for: turn)
    #expect(references.count == 1)
    #expect(references.first?.id == id)
    #expect(references.first?.isHistoryOwner == true && references.first?.wasActiveAtRequest == true)
    let exported = try JSONDecoder().decode(HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(turn))
    #expect(exported.historyTaskID == id && exported.decisionMetadata?.taskID == id)
}

@Test func historyTaskReferencesRetainDifferentOwnerAndRequestSnapshot() throws {
    let owner = UUID().uuidString
    let snapshot = UUID().uuidString
    let references = ConversationHistoryPresentation.taskReferences(
        for: try taskReferenceFixture(owner: owner, snapshot: snapshot))
    #expect(references.map(\.id) == [owner, snapshot])
    #expect(references[0].isHistoryOwner && !references[0].wasActiveAtRequest)
    #expect(!references[1].isHistoryOwner && references[1].wasActiveAtRequest)
}

@Test func historyTaskReferencesDoNotInventMissingOwnershipOrActivity() throws {
    let id = UUID().uuidString
    let ownerOnly = ConversationHistoryPresentation.taskReferences(
        for: try taskReferenceFixture(owner: id, snapshot: nil))
    #expect(ownerOnly.count == 1 && ownerOnly.first?.isHistoryOwner == true)
    #expect(ownerOnly.first?.wasActiveAtRequest == false)
    let snapshotOnly = ConversationHistoryPresentation.taskReferences(
        for: try taskReferenceFixture(owner: nil, snapshot: id))
    #expect(snapshotOnly.count == 1 && snapshotOnly.first?.wasActiveAtRequest == true)
    #expect(snapshotOnly.first?.isHistoryOwner == false)
    let absent = ConversationHistoryPresentation.taskReferences(
        for: try taskReferenceFixture(owner: nil, snapshot: nil))
    #expect(absent.isEmpty)
}

private func taskReferenceFixture(owner: String?, snapshot: String?) throws -> HistoryTurn {
    var turn = try #require(conversation(user: "fixture").turns.first)
    turn.historyTaskID = owner
    if let snapshot {
        turn.decisionMetadata = try JSONDecoder().decode(
            HistoryDecisionMetadata.self,
            from: JSONSerialization.data(withJSONObject: [
                "taskID": snapshot, "mode": "task", "skills": ["photography": 16], "catalogJSON": "{}",
            ]))
    }
    return turn
}

@Test func historyFunctionCatalogSeparatesRecordedActionsAndToolsWithoutChangingExport() throws {
    let source =
        #"{"actions":[{"path":"Camera.Preview.open","alias":"openCamera","channel":"Display","required":[],"optional":["lens"]},{"path":"Camera.Preview.close","alias":"closeCamera","channel":"Display","required":[],"optional":[]}],"tools":[{"path":"History.Conversation.read","alias":"readHistory","required":["id"],"optional":["offset"],"definitionJSON":"{\"type\":\"function\"}"}]}"#
    let catalog = try ConversationHistoryPresentation.functionCatalog(source)
    #expect(catalog.actions.map(\.alias) == ["openCamera", "closeCamera"])
    #expect(catalog.tools.count == 1 && catalog.tools[0].path == "History.Conversation.read")
    #expect(catalog.actions[0].channel == "Display" && catalog.actions[0].optional == ["lens"])
    #expect(catalog.tools[0].channel == nil && catalog.tools[0].required == ["id"])
    #expect(catalog.tools[0].definitionJSON == #"{"type":"function"}"#)
    var turn = try taskReferenceFixture(owner: nil, snapshot: nil)
    turn.decisionMetadata = try JSONDecoder().decode(
        HistoryDecisionMetadata.self,
        from: JSONSerialization.data(withJSONObject: ["mode": "default", "skills": [:], "catalogJSON": source]))
    let exported = try JSONDecoder().decode(HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(turn))
    #expect(exported.decisionMetadata?.catalogJSON == source)
}

@Test func historyFunctionCatalogShowsGenuineEmptyGroups() throws {
    let catalog = try ConversationHistoryPresentation.functionCatalog(#"{"actions":[],"tools":[]}"#)
    #expect(catalog.actions.isEmpty && catalog.tools.isEmpty)
}

@Test(arguments: [
    "invalid JSON", #"{"tools":[]}"#, #"{"actions":[],"tools":{}}"#,
    #"{"actions":[{"path":"Camera.Preview.open","alias":"openCamera"}],"tools":[]}"#,
])
func historyFunctionCatalogRejectsCorruptSnapshotsRatherThanInventingEmptyGroups(_ json: String) {
    #expect(throws: DecodingError.self) { try ConversationHistoryPresentation.functionCatalog(json) }
}
