import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import PlatformKit
import StorageChat
import StorageCore
import Testing

@testable import UI

private func archivePagingFixture(_ number: Int) throws -> HistoryConversation {
    try JSONDecoder().decode(
        HistoryConversation.self,
        from: JSONSerialization.data(withJSONObject: [
            "id": "dialog_\(number)", "createdAt": 0, "archivedAt": 1, "turnCount": 1,
            "turns": [], "taskCompressions": [],
        ]))
}

@Test @MainActor func historyArchivePagingRejectsNonProgressingResultsWithoutLooping() async throws {
    let state = ConversationHistoryState()
    var snapshot = HistorySnapshot()
    snapshot.past = try (21...40).reversed().map(archivePagingFixture)
    var reads = 0
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: { state.archive = snapshot }, deleteArchive: { _ in }, startNew: {},
        summarize: { _ in }, readConversation: { _ in throw HistoryDetailError.unavailable },
        readArchives: { _ in
            reads += 1
            return [try archivePagingFixture(21)]
        })
    await workflow.load()
    await workflow.loadMoreArchives(retry: false)
    #expect(state.archive?.past.count == 20 && state.archivePaging.error != nil && state.hasMoreArchives)
    await workflow.loadMoreArchives(retry: false)
    #expect(reads == 1 && !state.isBusy)
}

@Test @MainActor func historyArchivePagingRetainsErrorsUntilRetryAndStopsAtEOF() async throws {
    let state = ConversationHistoryState()
    var snapshot = HistorySnapshot()
    snapshot.past = try (21...40).reversed().map(archivePagingFixture)
    var attempts = 0
    var fail = true
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: { state.archive = snapshot }, deleteArchive: { _ in }, startNew: {},
        summarize: { _ in }, readConversation: { _ in throw HistoryDetailError.unavailable },
        readArchives: { cursor in
            #expect(cursor == 21)
            attempts += 1
            if fail { throw HistoryPhotoFixtureError.failed }
            return [try archivePagingFixture(20)]
        })
    await workflow.load()
    #expect(state.hasMoreArchives)
    await workflow.loadMoreArchives(retry: false)
    #expect(attempts == 1 && state.archive?.past.count == 20 && state.archivePaging.error != nil)
    #expect(state.status == nil && !state.isBusy)
    await workflow.loadMoreArchives(retry: false)
    #expect(attempts == 1)
    fail = false
    await workflow.loadMoreArchives(retry: true)
    #expect(attempts == 2 && state.archive?.past.count == 21 && state.archivePaging.error == nil)
    #expect(!state.hasMoreArchives)
    await workflow.loadMoreArchives(retry: false)
    #expect(attempts == 2)
    await workflow.load()
    #expect(state.hasMoreArchives && state.archive?.past.count == 20)
    await workflow.loadMoreArchives(retry: false)
    #expect(attempts == 3 && state.archive?.past.count == 21)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func historyArchivePagingJoinsOverlapAndIgnoresCancelledLatePage(throwsAfterCancellation: Bool) async throws {
    let state = ConversationHistoryState()
    var snapshot = HistorySnapshot()
    snapshot.past = try (21...40).reversed().map(archivePagingFixture)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var pending: CheckedContinuation<[HistoryConversation], any Error>?
    var calls = 0
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: { state.archive = snapshot }, deleteArchive: { _ in }, startNew: {},
        summarize: { _ in }, readConversation: { _ in throw HistoryDetailError.unavailable },
        readArchives: { _ in
            calls += 1
            if calls > 1 { return [] }
            entered.continuation.yield(())
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
    await workflow.load()
    let first = Task { await workflow.loadMoreArchives(retry: false) }
    var starts = entered.stream.makeAsyncIterator()
    await starts.next()
    #expect(state.isBusy && state.archivePaging.isLoading)
    await workflow.loadMoreArchives(retry: true)
    #expect(calls == 1)
    first.cancel()
    if throwsAfterCancellation {
        pending?.resume(throwing: HistoryPhotoFixtureError.failed)
    } else {
        pending?.resume(returning: [try archivePagingFixture(20)])
    }
    await first.value
    #expect(!state.isBusy && !state.archivePaging.isLoading && state.archivePaging.error == nil)
    #expect(state.archive?.past.count == 20)
    await workflow.loadMoreArchives(retry: false)
    #expect(calls == 2 && !state.hasMoreArchives && state.archive?.past.count == 20)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func historyRefreshJoinsPagingAndRetainsVisibleRecordsOnFailure(failRefresh: Bool) async throws {
    let state = ConversationHistoryState()
    var snapshot = HistorySnapshot()
    snapshot.past = try (21...40).reversed().map(archivePagingFixture)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var pending: CheckedContinuation<[HistoryConversation], any Error>?
    var refreshes = 0
    var reads = 0
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {},
        refresh: {
            refreshes += 1
            if refreshes > 1 && failRefresh { throw HistoryPhotoFixtureError.failed }
            state.archive = snapshot
        },
        deleteArchive: { _ in Issue.record("Refresh cannot admit a mutation") },
        startNew: { Issue.record("Refresh cannot admit a mutation") }, summarize: { _ in },
        readConversation: { _ in throw HistoryDetailError.unavailable },
        readArchives: { _ in
            reads += 1
            if reads > 1 { return [] }
            return try await withTaskCancellationHandler {
                entered.continuation.yield(())
                return try await withCheckedThrowingContinuation { pending = $0 }
            } onCancel: {
                cancelled.continuation.yield(())
            }
        })
    await workflow.load()
    let page = Task { await workflow.loadMoreArchives(retry: false) }
    var starts = entered.stream.makeAsyncIterator()
    await starts.next()
    let refresh = Task { await workflow.load() }
    var cancellations = cancelled.stream.makeAsyncIterator()
    await cancellations.next()
    #expect(state.isRefreshing && state.isBusy && refreshes == 1)
    // The native refresh indicator must remain active until the cancelled read has joined.
    await workflow.load()
    await workflow.loadMoreArchives(retry: true)
    workflow.startNew()
    #expect(refreshes == 1 && reads == 1)
    pending?.resume(returning: [try archivePagingFixture(20)])
    await page.value
    await refresh.value
    #expect(refreshes == 2 && state.archive?.past.count == 20)
    #expect(!state.isBusy && !state.isRefreshing && !state.archivePaging.isLoading)
    #expect((state.status != nil) == failRefresh && state.archivePaging.error == nil)
    await workflow.loadMoreArchives(retry: false)
    #expect(reads == 2 && !state.hasMoreArchives)
}

@Test @MainActor func canonicalConversationRetainsTaskSourcesAfterLiveStateRetirement() async throws {
    let store = AssistantHistoryStore()
    let input = UUID().uuidString
    let foreground = UUID().uuidString
    let taskData = try JSONSerialization.data(withJSONObject: [
        "historyOrder": 1, "id": foreground, "mode": "task", "goal": "帮我拍照", "date": 0,
        "status": "completed", "inputIDs": [input], "skills": ["photography"],
    ])
    var skills = AgentTaskSkillState()
    skills.tasks = [try JSONDecoder().decode(AgentTaskSkillState.TaskRecord.self, from: taskData)]
    var context = AgentContext(
        agentID: .assistant, scopeID: UUID().uuidString, state: AssistantContextState())
    context.state.skillState = skills
    let token = try await store.readCurrent().token
    _ = try await store.begin(id: input, user: "帮我拍照", request: [], expecting: token, model: "fixture")
    for text in ["帮我拍照", "拍照结果"] {
        try await store.beginModelRequest(
            .init(id: UUID().uuidString, input: text, requestJSON: "[]", historyTaskID: foreground),
            for: input)
        try await store.append("回复", to: input)
        try await store.finishModelRequest(input, reason: "stop")
    }
    try await store.finish(input, state: .completed)
    _ = try await store.startNew()
    context.state.history = try await store.snapshot()
    context.state.reconcileTaskCompressions()
    let conversation = try HistoryPresentationAdapter.conversation(context.state.history.past[0])
    let requests = ConversationHistoryPresentation.turns(conversation)
    #expect(requests.count == 2 && requests[1].isReACT == true)
    #expect(Set(requests.compactMap(\.ownerInputID)) == [input])
    let items = ConversationHistoryPresentation.timeline(conversation)
    guard case .task(let compression, let sources) = try #require(items.first) else {
        Issue.record("Canonical conversation must contain Task compression and original sources")
        return
    }
    #expect(compression.taskID == foreground && compression.goal == "帮我拍照")
    #expect(sources.count == 2 && sources.allSatisfy { $0.raw == "回复" })
    let list = try await HistoryPresentationAdapter.listPresentation(store)
    #expect(list.past.count == 1 && list.past[0].turns.isEmpty)
    context.state.skillState?.tasks = []
    let retired = try HistoryPresentationAdapter.conversation(context.state.history.past[0])
    #expect(ConversationHistoryPresentation.turns(retired).map(\.id) == requests.map(\.id))
    #expect(ConversationHistoryPresentation.timeline(retired).count == 1)

}

@Test @MainActor func failedHistoryLoadDoesNotCreateAnEphemeralStore() async {
    let state = ConversationHistoryState()
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: { throw CancellationError() },
        refresh: { Issue.record("Must not refresh after failed preparation") },
        deleteArchive: { _ in Issue.record("Must not delete after failed preparation") },
        startNew: { Issue.record("Must not archive after failed preparation") },
        summarize: { _ in Issue.record("Must not summarize after failed preparation") },
        readConversation: { _ in throw CancellationError() })
    await workflow.load()
    workflow.startNew()
    #expect(state.archive == nil && state.status != nil && !state.isBusy)
}

@Test @MainActor func requiredConversationReaderRejectsForeignIdentityWithoutReplacingSelection() async throws {
    let state = ConversationHistoryState()
    let previous = HistoryConversation()
    let supplied = try HistoryPresentationAdapter.conversation(
        AssistantConversation(id: "dialog_1"))
    state.selectedConversation = previous
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: {}, deleteArchive: { _ in }, startNew: {}, summarize: { _ in },
        readConversation: { _ in supplied })
    await #expect(throws: HistoryDetailError.unavailable) {
        try await workflow.loadConversation(UUID().uuidString)
    }
    #expect(state.selectedConversation?.id == previous.id)
    let selected = try await workflow.loadConversation(supplied.id)
    #expect(selected.id == supplied.id && state.selectedConversation?.id == supplied.id)
}

@Test(.timeLimit(.minutes(1))) @MainActor func historyFacadeForwardsOperationsAndJoinsCancellation() async {
    let state = ConversationHistoryState()
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var archives = 0
    var summaries: [String] = []
    var deletions: [String] = []
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: {}, deleteArchive: { deletions.append($0) },
        startNew: {
            archives += 1
            started.continuation.yield(())
            try await Task.sleep(for: .seconds(60))
        }, summarize: { summaries.append($0) }, readConversation: { _ in throw HistoryDetailError.unavailable })
    await workflow.load()
    var readiness = started.stream.makeAsyncIterator()
    workflow.startNew()
    await readiness.next()
    let id = "dialog_1"
    workflow.summarize(id)
    workflow.delete(id)
    workflow.startNew()
    #expect(archives == 1 && summaries.isEmpty && deletions.isEmpty)
    workflow.cancel()
    #expect(state.isBusy)
    await workflow.waitUntilIdle()
    #expect(!state.isBusy)
    workflow.summarize(id)
    await workflow.waitUntilIdle()
    workflow.delete(id)
    await workflow.waitUntilIdle()
    #expect(summaries == [id] && deletions == [id])
}

@Test @MainActor func historyAdapterRetainsPerRequestEvidenceAcrossCodableBoundary() async throws {
    let store = AssistantHistoryStore()
    let read = try await store.readCurrent()
    let id = "dialog_1"
    _ = try await store.begin(
        id: id, user: "question", request: [.init(role: .user, content: "question")], expecting: read.token,
        model: "fixture")
    let request = AssistantModelRequest(
        id: UUID().uuidString, input: "result",
        requestJSON: "[{\"role\":\"tool\",\"content\":\"result\",\"toolCallID\":\"provider\"}]")
    try await store.beginModelRequest(request, for: id)
    try await store.recordModelTiming(
        startedAt: request.date, firstTokenAt: request.date.addingTimeInterval(0.25), latency: 0.25, for: id)
    try await store.append("observed", to: id)
    try await store.finishModelRequest(id, reason: "stop")
    try await store.finish(id, state: .completed)
    let snapshot = try HistoryPresentationAdapter.presentationSnapshot(try await store.snapshot())
    let value = try #require(snapshot.current.turns.first?.modelRequests?.first)
    #expect(value.id == request.id && value.requestJSON == request.requestJSON)
    #expect(value.response == "observed" && value.firstTokenAt == request.date.addingTimeInterval(0.25))
    #expect(value.modelRequestStartedAt == request.date && value.firstTokenLatency == 0.25)
    #expect(ConversationHistoryPresentation.turns(snapshot.current).first?.request.last?.toolCallID == "provider")
}

private enum HistoryPhotoFixtureError: Error { case failed }

@MainActor private func loggedPhotoHistory(payload: String?) throws -> (ConversationHistoryWorkflow, String) {
    let round = UUID().uuidString
    var request: [String: Any] = [
        "id": round, "historyOrder": 1, "date": 0, "input": "photo", "requestJSON": "[]", "response": "done",
        "toolCalls": [],
        "state": "completed", "logsCleared": payload == nil,
    ]
    request["requestParametersJSON"] = payload
    let value: [String: Any] = [
        "version": 2, "past": [],
        "current": [
            "id": "dialog_1", "createdAt": 0, "taskCompressions": [],
            "turns": [
                [
                    "id": UUID().uuidString, "date": 0, "user": "photo", "request": [], "model": "fixture",
                    "temperature": 0.7, "response": "done", "state": "completed", "modelRequests": [request],
                ]
            ],
        ],
    ]
    let state = ConversationHistoryState()
    state.archive = try JSONDecoder().decode(HistorySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: {}, deleteArchive: { _ in }, startNew: {}, summarize: { _ in },
        readConversation: { _ in throw HistoryDetailError.unavailable })
    return (workflow, round)
}

@Test @MainActor func historyImagesReadOnlyRecordedHTTPBytesAndRejectMissingLogs() async throws {
    let bytes = Data([1, 2, 3])
    let payload = String(
        decoding: try JSONSerialization.data(withJSONObject: [
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_image", "image_url": "data:image/png;base64," + bytes.base64EncodedString()]
                    ],
                ]
            ]
        ]), as: UTF8.self)
    let (workflow, round) = try loggedPhotoHistory(payload: payload)
    #expect(try await workflow.imageData("http_image_1", for: round) == bytes)
    await #expect(throws: HistoryImageLoadingError.invalidReference) {
        try await workflow.imageData("media_1", for: round)
    }
    await #expect(throws: HistoryImageLoadingError.invalidReference) {
        try await workflow.imageData("http_image_1", for: "foreign")
    }
    let (cleared, clearedRound) = try loggedPhotoHistory(payload: nil)
    await #expect(throws: HistoryImageLoadingError.invalidReference) {
        try await cleared.imageData("http_image_1", for: clearedRound)
    }
}

@Test @MainActor func canonicalConversationSeparatesTwoTasksWithinOneInput() async throws {
    let store = AssistantHistoryStore()
    let input = UUID().uuidString
    let taskA = UUID().uuidString
    let taskB = UUID().uuidString
    let token = try await store.readCurrent().token
    _ = try await store.begin(id: input, user: "两个目标", request: [], expecting: token, model: "stub")
    for id in [taskA, taskB] {
        try await store.beginModelRequest(
            .init(id: UUID().uuidString, input: "goal", requestJSON: "[]", historyTaskID: id), for: input)
        try await store.append(id, to: input)
        try await store.finishModelRequest(input, reason: "stop")
    }
    try await store.finish(input, state: .completed)
    var context = AgentContext(
        agentID: .assistant, scopeID: UUID().uuidString, state: AssistantContextState())
    context.state.history = try await store.snapshot()
    for id in [taskA, taskB] {
        let request = try #require(
            context.state.history.current.turns[0].modelRequests?.first { $0.historyTaskID == id })
        context.state.history.current.taskCompressions.append(
            .init(
                taskID: id, goal: id, status: .completed, reportedSummary: "done", failure: nil,
                completedAt: Date(), sources: [.init(inputID: input, requestID: request.id)]))
    }
    let conversation = try HistoryPresentationAdapter.conversation(context.state.history.current)
    let items = ConversationHistoryPresentation.timeline(conversation)
    #expect(items.count == 2 && Set(items.map(\.id)) == [taskA, taskB])
    for item in items {
        guard case .task(let compression, let sources) = item else {
            Issue.record("Expected expandable Task compression")
            continue
        }
        #expect(sources.count == 1 && sources[0].id == compression.sources[0].requestID)
    }
}
