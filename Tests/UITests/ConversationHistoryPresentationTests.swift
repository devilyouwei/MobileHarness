import Foundation
import Testing

@testable import UI

@Test func historyReturningFromChildKeepsInitialLoadClosedUntilPageIsRecreated() {
    var lifecycle = HistoryInitialLoad()
    let first = lifecycle.begin()
    let overlapping = lifecycle.begin()
    #expect(first && !overlapping)
    lifecycle.finish(succeeded: true)
    for _ in 0..<3 {
        let returningFromDetail = lifecycle.begin()
        #expect(!returningFromDetail)
    }
    // A failed explicit refresh must not turn navigation return into another refresh.
    lifecycle.finish(succeeded: false)
    let afterRefreshFailure = lifecycle.begin()
    #expect(!afterRefreshFailure)
    var newPage = HistoryInitialLoad()
    let enteringNewPage = newPage.begin()
    #expect(enteringNewPage)
}

@Test func historyInitialFailureOrCancellationCanRetryAndExplicitRefreshCanCompleteLoad() {
    var lifecycle = HistoryInitialLoad()
    let first = lifecycle.begin()
    #expect(first)
    lifecycle.finish(succeeded: false)
    let retry = lifecycle.begin()
    #expect(retry)
    lifecycle.finish(succeeded: false)
    // Pull-to-refresh or the retry button can load successfully outside the appearance callback.
    lifecycle.finish(succeeded: true)
    let afterManualRetry = lifecycle.begin()
    #expect(!afterManualRetry)
}

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
    #expect(ConversationHistoryPresentation.title(try conversation()) == "New Conversation")
    #expect(ConversationHistoryPresentation.title(try conversation(user: "  original input  ")) == "  original input  ")
    #expect(ConversationHistoryPresentation.title(try conversation(archived: true)) == "Title Pending")
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
    #expect(
        rows[0].toolCalls?.first?.responseReport
            == "Tool Call · inspect · completed\n\nArguments:\n{}\n\nResult:\nactual-result")
    #expect(rows[0].firstTokenReport == "Time to first token: ")
    #expect(rows[1].user == "[tool]\nactual-result" && rows[1].isReACT == true)
    #expect(rows[1].raw == "observed" && rows[1].toolCalls?.isEmpty == true)
    #expect(rows[1].request.last?.role == .tool && rows[1].request.last?.toolCallID == "provider-call")
    #expect(rows[1].request[2].toolCalls?.first?.name == "inspect")
    #expect(rows[1].firstTokenReport == "Time to first token: 0.025 sec")
    #expect(rows[1].toolDefinitions == ["definition"])
    let secondExport = try JSONDecoder().decode(
        HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(rows[1]))
    #expect(secondExport.requestJSON == requestJSON && secondExport.user == "[tool]\nactual-result")
    #expect(secondExport.raw == "observed" && secondExport.request.last?.toolCallID == "provider-call")
    let firstExport = try JSONDecoder().decode(
        HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(rows[0]))
    #expect(firstExport.toolCalls?.first?.output == "actual-result")
}

@Test func historyToolResponsesKeepMixedTextMultipleCallsAndFailures() throws {
    let calls: [[String: Any]] = [
        [
            "id": "first", "providerID": "provider-1", "name": "History.list", "argumentsJSON": "{}",
            "state": "completed", "output": "",
        ],
        [
            "id": "second", "providerID": "provider-2", "name": "History.read",
            "argumentsJSON": #"{"id":"dialog_1"}"#, "state": "failed", "error": "missingConversation",
        ],
        [
            "id": "third", "providerID": "provider-3", "name": "History.list", "argumentsJSON": "{}",
            "state": "received",
        ],
    ]
    let page = try historyFixture(extra: [
        "modelRequests": [
            [
                "historyOrder": 1, "id": "mixed", "date": 0, "input": "read", "requestJSON": "[]",
                "response": "checking",
                "toolCalls": calls, "state": "completed",
                "modelRequestStartedAt": 10, "firstTokenAt": 10.125, "firstTokenLatency": 0.125,
            ]
        ]
    ])
    let turn = try #require(ConversationHistoryPresentation.turns(page).first)
    let reports = try #require(turn.toolCalls).map(\.responseReport)
    #expect(turn.raw == "checking" && reports.count == 3)
    #expect(reports[0].hasSuffix("Result:\n"))
    #expect(reports[1].contains(#"{"id":"dialog_1"}"#))
    #expect(reports[1].hasSuffix("Error:\nmissingConversation") && !reports[1].contains("Result:"))
    #expect(!reports[2].contains("Result:") && !reports[2].contains("Error:"))
    #expect(turn.firstTokenReport == "Time to first token: 0.125 sec")
    let exported = try JSONDecoder().decode(HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(turn))
    #expect(exported.response == "checking" && exported.toolCalls?.count == 3)
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

@Test func historyMessageMetadataCannotRestoreImagesWithoutRequestLogs() throws {
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
    #expect(row.attachedImages.isEmpty && row.displayInput == "photo" + marker)
    #expect(row.request.first?.content.contains("bytes omitted") == true)
}

@Test func historyImageReferencesRejectInvalidMetadataAndBoundTheGallery() {
    let valid = (0..<6).map { _ in
        HistoryImageReference(id: UUID().uuidString, mimeType: "image/png", byteCount: 1)
    }
    #expect(HistoryMessage(role: .user, content: "", imageReferences: valid).attachedImages.count == 5)
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
    #expect(row.firstTokenReport == "Time to first token: ")
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

@Test func historyCacheUsageDistinguishesZeroFromMissingAndPreservesExport() throws {
    let legacy = try JSONDecoder().decode(
        HistoryTokenUsage.self, from: Data(#"{"input":12,"generated":2,"total":14}"#.utf8))
    #expect(legacy.cachedInput == nil && legacy.cacheWriteInput == nil)
    let snapshot = try historyFixture(extra: [
        "tokenUsage": ["input": 12, "generated": 2, "total": 14, "cachedInput": 0, "cacheWriteInput": 4]
    ])
    let turn = try #require(snapshot.turns.first)
    #expect(turn.tokenReport.contains("Cache read: 0 tokens"))
    #expect(turn.tokenReport.contains("Cache write: 4 tokens"))
    let exported = try JSONDecoder().decode(HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(turn))
    #expect(exported.tokenUsage?.cachedInput == 0 && exported.tokenUsage?.cacheWriteInput == 4)
    let older = try historyFixture(extra: ["tokenUsage": ["input": 12, "generated": 2, "total": 14]])
    #expect(older.turns.first?.tokenReport.contains("缓存") == false)
}

@MainActor private func awaitHistoryRead(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    try #require(ready())
}

@Test @MainActor func historyMessageReadCancellationRejectsLateNavigationAndErrors() async throws {
    let loader = HistoryMessageLoader()
    let turn = try #require(conversation(user: "read").turns.first)
    var pending: CheckedContinuation<HistoryTurn, Error>?
    var shown: HistoryTurn?
    loader.open(read: { try await withCheckedThrowingContinuation { pending = $0 } }, show: { shown = $0 })
    try await awaitHistoryRead { pending != nil }
    loader.cancel()
    pending?.resume(returning: turn)
    await loader.stopAndWait()
    #expect(shown == nil && loader.error == nil && !loader.isLoading)
    loader.open(read: { throw CancellationError() }, show: { shown = $0 })
    try await awaitHistoryRead { !loader.isLoading }
    #expect(loader.error == nil && shown == nil)
    await loader.stopAndWait()
}

@Test @MainActor func historyMessageReadsRejectDuplicatesAndJoinBeforeReplacement() async throws {
    let loader = HistoryMessageLoader()
    let turn = try #require(conversation(user: "read").turns.first)
    var pending: CheckedContinuation<HistoryTurn, Error>?
    var reads = 0
    var shows = 0
    loader.open(
        read: {
            reads += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }, show: { _ in shows += 1 })
    loader.open(
        read: {
            reads += 1
            return turn
        }, show: { _ in shows += 1 })
    try await awaitHistoryRead { pending != nil }
    #expect(reads == 1)
    loader.cancel()
    loader.open(
        read: {
            reads += 1
            return turn
        }, show: { _ in shows += 1 })
    for _ in 0..<5 { await Task.yield() }
    #expect(reads == 1)
    pending?.resume(returning: turn)
    try await awaitHistoryRead { shows == 1 }
    #expect(reads == 2 && loader.error == nil && !loader.isLoading)
    await loader.stopAndWait()
}

@Test func historyAsyncProjectionPreservesTimelineAndCancelledCatalogDoesNotComplete() async throws {
    let page = try taskPreviewPage()
    let projected = try await ConversationHistoryPresentation.timelineOffMain(page)
    #expect(projected.map(\.id) == ConversationHistoryPresentation.timeline(page).map(\.id))
    let catalog = try await ConversationHistoryPresentation.functionCatalogOffMain(#"{"actions":[],"tools":[]}"#)
    #expect(catalog.actions.isEmpty && catalog.tools.isEmpty)
    let cancelled = Task {
        while !Task.isCancelled { await Task.yield() }
        return try await ConversationHistoryPresentation.functionCatalogOffMain(#"{"actions":[],"tools":[]}"#)
    }
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        Issue.record("Cancelled catalog parsing must reject its result")
    } catch is CancellationError {}
}

@Test func writerWorkspaceSummaryExportsDatesAndCountsWithoutExecutionStatus() throws {
    var task = WriterWorkspaceItem(
        workspaceID: "workspace_1", title: "test",
        updatedAt: Date(timeIntervalSince1970: 200))
    task.startedAt = Date(timeIntervalSince1970: 100)
    task.requestCount = 7
    let data = try JSONEncoder().encode(task)
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(fields["status"] == nil && fields["phase"] == nil && fields["failure"] == nil)
    #expect(fields["completedDuration"] == nil && fields["activeSince"] == nil)
    let restored = try JSONDecoder().decode(WriterWorkspaceItem.self, from: data)
    #expect(restored.startedAt == task.startedAt && restored.updatedAt == task.updatedAt && restored.requestCount == 7)
}
@Test func writerRequestTimingDistinguishesUnknownActiveAndCompleted() {
    var request = HistoryModelRequest(
        id: "request", date: Date(timeIntervalSince1970: 100), input: "", requestJSON: "[]",
        modelRequestStartedAt: nil, firstTokenLatency: nil, firstTokenAt: nil, response: "",
        toolCalls: [], tokenUsage: nil, state: .completed, finishReason: "stop", error: nil)
    #expect(WriterRecordPresentation.firstToken(request) == "Time to first token: Unknown")
    #expect(WriterRecordPresentation.requestDuration(request, at: Date()) == "Total duration: Unknown")
    request.modelRequestCompletedAt = Date(timeIntervalSince1970: 102)
    #expect(WriterRecordPresentation.requestDuration(request, at: Date()) == "Total duration: 2.000 sec")
    let active = HistoryModelRequest(
        id: "active", date: Date(timeIntervalSince1970: 100), input: "", requestJSON: "[]",
        modelRequestStartedAt: Date(timeIntervalSince1970: 101), firstTokenLatency: 0.5,
        firstTokenAt: Date(timeIntervalSince1970: 101.5), response: "", toolCalls: [], tokenUsage: nil,
        state: .generating, finishReason: nil, error: nil)
    #expect(WriterRecordPresentation.firstToken(active) == "Time to first token: 0.500 sec")
    #expect(
        WriterRecordPresentation.requestDuration(active, at: Date(timeIntervalSince1970: 103))
            == "Total duration: 2.000 sec")

}

@Test func writerRequestRowsShowConciseTitlesRetryAndLocalizedStatus() {
    let request = WriterRequestItem(
        id: "request", position: 1, number: 12, delegateID: "run", phase: "control", path: nil,
        attempt: 2, date: Date(), state: "cancelled", title: "修改流程图布局")
    #expect(request.displayTitle == "修改流程图布局 (retry)")
    #expect(request.statusTitle == "Cancelled")
    #expect(request.number == 12)
}

@Test func historyListDatesRespectCalendarYearAndTimeZoneWithoutInferringActivity() throws {
    let parser = ISO8601DateFormatter()
    let now = try #require(parser.date(from: "2025-12-31T17:00:00Z"))
    let current = try #require(parser.date(from: "2025-12-31T16:05:00Z"))
    let previous = try #require(parser.date(from: "2025-12-31T15:59:00Z"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
    #expect(HistoryListPresentation.date(current, relativeTo: now, calendar: calendar) == "01/01 00:05")
    #expect(HistoryListPresentation.date(previous, relativeTo: now, calendar: calendar) == "2025/12/31 23:59")
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    #expect(HistoryListPresentation.date(current, relativeTo: now, calendar: calendar) == "12/31 16:05")
}

@Test func historyLogDeletionPreservesBusinessStatesAndRemovesCachedLogsFromExport() throws {
    var turn = try taskReferenceFixture(owner: "task_1", snapshot: "task_1")
    turn.decisionMetadata?.states = ["ui.navigation", "platform.device"]
    turn.requestParametersJSON = #"{"model":"fixture","messages":[]}"#
    turn.responseEventsJSON = "raw response evidence"
    turn.messageID = "request_1"
    let cleared = ConversationHistoryPresentation.clearingLogs(turn)
    #expect(cleared.logsCleared == true && cleared.request.isEmpty && cleared.attachedImages.isEmpty)
    #expect(cleared.requestJSON == nil && cleared.requestParametersJSON == nil && cleared.responseEventsJSON == nil)
    #expect(cleared.tokenUsage == nil && cleared.firstTokenAt == nil && cleared.firstTokenLatency == nil)
    #expect(cleared.generationRounds == nil && cleared.modelRequests == nil && cleared.model.isEmpty)
    #expect(cleared.id == turn.id && cleared.messageID == turn.messageID && cleared.response == turn.response)
    #expect(
        cleared.historyTaskID == turn.historyTaskID && cleared.decisionMetadata?.skills == turn.decisionMetadata?.skills
    )
    #expect(cleared.decisionMetadata?.states == ["ui.navigation", "platform.device"])
    #expect(cleared.decisionMetadata?.catalogJSON == turn.decisionMetadata?.catalogJSON)
    let exported = try JSONDecoder().decode(HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(cleared))
    #expect(exported.logsCleared == true && exported.responseEventsJSON == nil && exported.request.isEmpty)
    #expect(exported.decisionMetadata?.states == ["ui.navigation", "platform.device"])
}

@Test func historyStateSelectionDistinguishesUnrecordedFromEmpty() throws {
    var turn = try taskReferenceFixture(owner: nil, snapshot: "task_1")
    #expect(turn.decisionMetadata?.states == nil)
    turn.decisionMetadata?.states = []
    let restored = try JSONDecoder().decode(HistoryTurn.self, from: ConversationHistoryPresentation.jsonData(turn))
    #expect(restored.decisionMetadata?.states == [])
}

@Test(arguments: [
    #"{"messages":[{"role":"system","content":"rules"},{"role":"user","content":"old"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"workspace","arguments":"{\"command\":\"read\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"file result"},{"role":"user","content":"revise"}]}"#,
    #"{"input":[{"role":"system","content":[{"type":"input_text","text":"rules"}]},{"role":"user","content":[{"type":"input_text","text":"old"}]},{"type":"function_call","call_id":"call_1","name":"workspace","arguments":"{\"command\":\"read\"}"},{"type":"function_call_output","call_id":"call_1","output":"file result"},{"role":"user","content":[{"type":"input_text","text":"revise"}]}]}"#,
    #"[{"role":"system","content":"rules"},{"role":"user","content":"old"},{"role":"assistant","content":"","toolCalls":[{"id":"call_1","name":"workspace","argumentsJSON":"{\"command\":\"read\"}"}]},{"role":"tool","toolCallID":"call_1","content":"file result"},{"role":"user","content":"revise"}]"#,
])
func writerFormattedPromptsKeepToolPairsAndSelectOnlyCurrentInput(_ json: String) throws {
    var request = try #require(conversation(user: "stored goal").turns.first?.modelRequests?.first)
    request.requestParametersJSON = json
    let messages = WriterRecordPresentation.promptMessages(request)
    #expect(messages.count == 5)
    #expect(messages[2].toolCalls?.first?.name == "workspace" && messages[2].toolCalls?.first?.id == "call_1")
    #expect(messages[2].toolCalls?.first?.argumentsJSON == #"{"command":"read"}"#)
    let current = WriterRecordPresentation.inputMessages(messages)
    #expect(current.map(\.content) == ["file result", "revise"])
    #expect(current.first?.role == .tool && current.first?.toolCallID == "call_1")
    request.logsCleared = true
    #expect(WriterRecordPresentation.promptMessages(request).isEmpty)
}

@Test func writerClearingLogsPreservesTextToolResultsAndRuntimeBusinessEvidence() throws {
    let call: [String: Any] = [
        "id": "execution_1", "providerID": "call_1", "name": "workspace", "argumentsJSON": "{}",
        "state": "completed", "output": "saved file",
    ]
    let source = try historyFixture(extra: [
        "modelRequests": [
            [
                "id": "request_1", "date": 0, "historyOrder": 1, "input": "full input", "requestJSON": "[]",
                "producerMetadata": ["path": "styles/main.css", "phase": "文件内容请求"],
                "inputMessages": [
                    ["role": "tool", "content": "read file", "toolCallID": "earlier", "toolName": "workspace"]
                ],
                "requestParametersJSON": #"{"input":[]}"#, "responseEventsJSON": "raw events",
                "model": "fixture", "temperature": 0.2, "maximumOutputTokens": 100,
                "response": "generated content", "toolCalls": [call], "state": "completed",
                "decisionMetadata": [
                    "mode": "control", "skills": [:],
                    "catalogJSON":
                        #"{"actions":[],"tools":[{"alias":"workspace","path":"Artifacts.Workspace.perform","required":[],"optional":[],"definitionJSON":"definition"}]}"#,
                ],
                "tokenUsage": ["input": 1, "generated": 2, "total": 3], "firstTokenLatency": 0.5,
            ]
        ]
    ])
    let recorded = try #require(source.turns.first?.modelRequests?.first)
    var detail = WriterRequestDetails(
        summary: .init(
            id: "request_1", position: 1, number: 1, delegateID: "run", phase: "control", path: nil,
            attempt: 1, date: recorded.date, state: "completed"),
        request: recorded, fallbackInput: "full input", toolSources: ["earlier": "request_0"],
        finalization: .init(state: .completed, result: "committed file", error: nil))
    detail.clearLogs()
    let request = try #require(detail.request)
    #expect(request.logsCleared == true && request.state == .completed)
    #expect(detail.summary.state == "completed" && detail.toolSources == ["earlier": "request_0"])
    #expect(request.input == "full input" && request.response == "generated content")
    #expect(WriterRecordPresentation.contentPath(request) == "styles/main.css")
    #expect(request.inputMessages?.first?.content == "read file")
    #expect(request.inputMessages?.first?.toolName == "workspace")
    #expect(try WriterRecordPresentation.tools(request)?.first?.alias == "workspace")
    #expect(try WriterRecordPresentation.tools(request)?.first?.definitionJSON == "definition")
    #expect(request.toolCalls.first?.output == "saved file" && request.toolCalls.first?.providerID == "call_1")
    #expect(detail.finalization?.result == "committed file")
    #expect(request.requestParametersJSON == nil && request.responseEventsJSON == nil && request.requestJSON == "[]")
    #expect(request.tokenUsage == nil && request.firstTokenLatency == nil)
    #expect(request.model == nil && request.temperature == nil && request.maximumOutputTokens == nil)
}

@Test func writerRequestInputSummarizesRecordedDraftChangesAndBoundsOtherPreviews() {
    let input =
        #"[{"status":"draft edited; render before finish","beforeBytes":"0","firstChangedLine":"1","afterBytes":"5464","path":"index.html"}]"#
    let summary = WriterRecordPresentation.inputSummary(input, isTool: true)
    #expect(summary == "index.html · Draft changed, pending render\n0 → 5464 bytes · First changed line 1")
    #expect(WriterRecordPresentation.inputSummary(input, isTool: false) == input)
    #expect(WriterRecordPresentation.inputSummary(String(repeating: "字", count: 250), isTool: true).count == 241)
}

@Test func writerRequestToolsDistinguishMissingEmptyAndMalformedCatalogs() throws {
    var request = try #require(conversation(user: "input").turns.first?.modelRequests?.first)
    request.decisionMetadata = nil
    #expect(try WriterRecordPresentation.tools(request) == nil)
    request.decisionMetadata = .init(
        taskID: nil, mode: "content", skills: [:], catalogJSON: #"{"actions":[],"tools":[]}"#)
    #expect(try WriterRecordPresentation.tools(request)?.isEmpty == true)
    request.decisionMetadata = .init(
        taskID: nil, mode: "control", skills: [:],
        catalogJSON:
            #"{"actions":[],"tools":[{"alias":"workspace","path":"Artifacts.Workspace.perform","required":["command"],"optional":[],"definitionJSON":"native declaration"}]}"#
    )
    request.logsCleared = true
    // The business catalog remains available even when prompt logs are removed.
    #expect(try WriterRecordPresentation.tools(request)?.first?.definitionJSON == "native declaration")
    request.decisionMetadata = .init(taskID: nil, mode: "control", skills: [:], catalogJSON: "invalid")
    #expect(throws: (any Error).self) { try WriterRecordPresentation.tools(request) }
}

private struct WriterPageFixture: Identifiable, Sendable {
    let id: Int
    var title: String = "original"
}

@Test func writerRecordPagesKeepLoadedRowsAndTerminalCursorAcrossNavigationAndPolling() throws {
    var pages = WriterRecordPages<WriterPageFixture, Int>()
    #expect(!pages.hasLoaded)
    try pages.apply((1...20).map { .init(id: $0) }, next: 20, reset: true)
    try pages.apply((21...40).map { .init(id: $0) }, next: nil, reset: false)
    // Reappearing pages use hasLoaded rather than replaying their initial read.
    #expect(pages.hasLoaded && pages.items.count == 40 && pages.next == nil)
    for _ in 0..<3 {
        try pages.apply((21...40).map { .init(id: $0, title: "updated") }, next: nil, reset: false)
    }
    #expect(pages.items.map(\.id) == Array(1...40) && pages.next == nil)
    #expect(pages.items.first?.title == "original" && pages.items.last?.title == "updated")
    // New rows found by tail polling can advertise a real following page.
    try pages.apply((21...40).map { .init(id: $0) }, next: 40, reset: false)
    try pages.apply([.init(id: 41)], next: nil, reset: false)
    #expect(pages.items.map(\.id) == Array(1...41) && pages.next == nil)
    try pages.apply([.init(id: 1)], next: nil, reset: true)
    #expect(pages.hasLoaded && pages.items.map(\.id) == [1])
    try pages.apply([], next: nil, reset: true)
    #expect(pages.hasLoaded && pages.items.isEmpty && pages.next == nil)
}

@Test func writerRecordPagesRejectCancelledRefreshWithoutDroppingLoadedRows() async throws {
    var initial = WriterRecordPages<WriterPageFixture, Int>()
    try initial.apply((1...40).map { .init(id: $0) }, next: 40, reset: true)
    let snapshot = initial
    let worker = Task {
        var pages = snapshot
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(throws: CancellationError.self) {
            try pages.apply([.init(id: 1)], next: nil, reset: true)
        }
        return pages
    }
    let preserved = await worker.value
    #expect(preserved.hasLoaded && preserved.items.count == 40 && preserved.next == 40)
    var retry = preserved
    try retry.apply([.init(id: 41)], next: nil, reset: false)
    #expect(retry.items.map(\.id) == Array(1...41) && retry.next == nil)
}

@Test func writerRecordPagesRefreshNewestWithoutReplacingOlderCursor() throws {
    var pages = WriterRecordPages<WriterPageFixture, Int>()
    try pages.apply((21...40).reversed().map { .init(id: $0) }, next: 21, reset: true)
    try pages.replaceHead((31...43).reversed().map { .init(id: $0, title: "updated") }, replacing: 10)
    #expect(pages.items.map(\.id) == Array((21...43).reversed()) && pages.next == 21)
    #expect(pages.items[12].title == "updated" && pages.items[13].title == "original")
    try pages.apply((1...20).reversed().map { .init(id: $0) }, next: nil, reset: false)
    #expect(pages.items.map(\.id) == Array((1...43).reversed()) && pages.next == nil)
}
