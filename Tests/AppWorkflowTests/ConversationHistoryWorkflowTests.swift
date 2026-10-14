import AgentCore
import Agents
import AppWorkflows
import Foundation
import StorageChat
import Testing
import UI

@Test @MainActor func canonicalConversationRetainsTaskSourcesAfterLiveStateRetirement() async throws {
    let store = ConversationHistoryStore()
    let input = UUID()
    let foreground = UUID()
    let taskData = try JSONSerialization.data(withJSONObject: [
        "historyOrder": 1, "id": foreground.uuidString, "mode": "task", "goal": "帮我拍照", "date": 0,
        "status": "completed", "inputIDs": [input.uuidString], "skills": ["photography"],
    ])
    var skills = AgentTaskSkillState()
    skills.tasks = [try JSONDecoder().decode(AgentTaskSkillState.TaskRecord.self, from: taskData)]
    var context = AgentContext(agentID: .assistant, scopeID: UUID(), state: AssistantContextState())
    context.state.skillState = skills
    let token = try await store.readCurrent().token
    _ = try await store.begin(id: input, user: "帮我拍照", request: [], expecting: token, model: "fixture")
    for text in ["帮我拍照", "拍照结果"] {
        try await store.beginModelRequest(
            .init(id: UUID(), input: text, requestJSON: "[]", historyTaskID: foreground), for: input)
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
        summarize: { _ in Issue.record("Must not summarize after failed preparation") }, previewOutput: { _ in "" },
        readConversation: { _ in throw CancellationError() },
        readPhoto: { _, _ in nil })
    await workflow.load()
    workflow.startNew()
    #expect(state.archive == nil && state.status != nil && !state.isBusy)
}

@Test @MainActor func requiredConversationReaderRejectsForeignIdentityWithoutReplacingSelection() async throws {
    let state = ConversationHistoryState()
    let previous = HistoryConversation()
    let supplied = HistoryConversation()
    state.selectedConversation = previous
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: {}, deleteArchive: { _ in }, startNew: {}, summarize: { _ in },
        previewOutput: { _ in "" }, readConversation: { _ in supplied }, readPhoto: { _, _ in nil })
    await #expect(throws: HistoryDetailError.unavailable) { try await workflow.loadConversation(UUID()) }
    #expect(state.selectedConversation?.id == previous.id)
    let selected = try await workflow.loadConversation(supplied.id)
    #expect(selected.id == supplied.id && state.selectedConversation?.id == supplied.id)
}

@Test(.timeLimit(.minutes(1))) @MainActor func historyFacadeForwardsOperationsAndJoinsCancellation() async {
    let state = ConversationHistoryState()
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var archives = 0
    var summaries: [UUID] = []
    var deletions: [UUID] = []
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: {}, deleteArchive: { deletions.append($0) },
        startNew: {
            archives += 1
            started.continuation.yield(())
            try await Task.sleep(for: .seconds(60))
        }, summarize: { summaries.append($0) }, previewOutput: { _ in "" },
        readConversation: { _ in throw HistoryDetailError.unavailable }, readPhoto: { _, _ in nil })
    await workflow.load()
    var readiness = started.stream.makeAsyncIterator()
    workflow.startNew()
    await readiness.next()
    let id = UUID()
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
    let store = ConversationHistoryStore()
    let read = try await store.readCurrent()
    let id = UUID()
    _ = try await store.begin(
        id: id, user: "question", request: [.init(role: .user, content: "question")], expecting: read.token,
        model: "fixture")
    let request = ConversationModelRequest(
        id: UUID(), input: "result",
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

@MainActor private func photoHistory(
    read: @escaping @MainActor (UUID, UUID) async throws -> Data?
) throws -> (ConversationHistoryWorkflow, UUID, UUID, UUID) {
    let owner = UUID()
    let round = UUID()
    let photo = UUID()
    let request =
        "[{\"role\":\"user\",\"content\":\"photo\",\"imageReferences\":[{\"id\":\"\(photo.uuidString)\",\"mimeType\":\"image/jpeg\",\"byteCount\":1}]}]"
    let value: [String: Any] = [
        "version": 2, "past": [],
        "current": [
            "historyOrder": 1, "id": UUID().uuidString, "createdAt": 0, "taskCompressions": [],
            "turns": [
                [
                    "historyOrder": 1, "id": owner.uuidString, "date": 0, "user": "photo", "request": [],
                    "model": "fixture",
                    "temperature": 0.7,
                    "response": "", "state": "completed",
                    "modelRequests": [
                        [
                            "historyOrder": 1, "id": round.uuidString, "date": 0, "input": "photo",
                            "requestJSON": request,
                            "response": "", "toolCalls": [], "state": "completed",
                        ]
                    ],
                ]
            ],
        ],
    ]
    let state = ConversationHistoryState()
    state.archive = try JSONDecoder().decode(HistorySnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: {}, refresh: {}, deleteArchive: { _ in }, startNew: {}, summarize: { _ in },
        previewOutput: { _ in "" },
        readConversation: { id in
            guard let value = state.archive?.current, value.id == id else { throw HistoryDetailError.unavailable }
            return value
        }, readPhoto: read)
    return (workflow, photo, round, owner)
}

@Test @MainActor func historyPhotoReaderChecksAttachmentAndOriginalInputBeforeRead() async throws {
    var requests: [(UUID, UUID)] = []
    let (workflow, photo, round, owner) = try photoHistory { id, input in
        requests.append((id, input))
        return Data([1])
    }
    #expect(try await workflow.imageData(photo, for: round) == Data([1]))
    #expect(requests.count == 1 && requests[0].0 == photo && requests[0].1 == owner)
    await #expect(throws: HistoryImageLoadingError.invalidReference) {
        try await workflow.imageData(UUID(), for: round)
    }
    await #expect(throws: HistoryImageLoadingError.invalidReference) {
        try await workflow.imageData(photo, for: UUID())
    }
    #expect(requests.count == 1)
}

@Test @MainActor func historyPhotoReaderPreservesMissingAndFailedOutcomesAndReleasesAdmission() async throws {
    var attempt = 0
    let (workflow, photo, round, _) = try photoHistory { _, _ in
        attempt += 1
        switch attempt {
        case 1: return nil
        case 2: throw HistoryPhotoFixtureError.failed
        case 3: return Data(repeating: 1, count: 4 * 1024 * 1024 + 1)
        default: return Data([1])
        }
    }
    #expect(try await workflow.imageData(photo, for: round) == nil)
    await #expect(throws: HistoryPhotoFixtureError.failed) { try await workflow.imageData(photo, for: round) }
    await #expect(throws: HistoryImageLoadingError.oversizedImage) { try await workflow.imageData(photo, for: round) }
    #expect(try await workflow.imageData(photo, for: round) == Data([1]))
}

@Test(.timeLimit(.minutes(1))) @MainActor func historyPhotoReaderBoundsConcurrentReadsAndJoinsCancellation()
    async throws
{
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
    var pending: [CheckedContinuation<Data?, Never>] = []
    let (workflow, photo, round, _) = try photoHistory { _, _ in
        entered.continuation.yield(())
        return await withCheckedContinuation { pending.append($0) }
    }
    let reads = (0..<4).map { _ in Task { try await workflow.imageData(photo, for: round) } }
    var starts = entered.stream.makeAsyncIterator()
    for _ in 0..<4 { await starts.next() }
    await #expect(throws: HistoryImageLoadingError.busy) { try await workflow.imageData(photo, for: round) }
    reads[0].cancel()
    pending[0].resume(returning: Data([1]))
    await #expect(throws: CancellationError.self) { try await reads[0].value }
    let replacement = Task { try await workflow.imageData(photo, for: round) }
    await starts.next()
    for waiter in pending.dropFirst() { waiter.resume(returning: Data([1])) }
    for read in reads.dropFirst() { #expect(try await read.value == Data([1])) }
    #expect(try await replacement.value == Data([1]))
}

@Test @MainActor func canonicalConversationSeparatesTwoTasksWithinOneInput() async throws {
    let store = ConversationHistoryStore()
    let input = UUID()
    let taskA = UUID()
    let taskB = UUID()
    let token = try await store.readCurrent().token
    _ = try await store.begin(id: input, user: "两个目标", request: [], expecting: token, model: "stub")
    for id in [taskA, taskB] {
        try await store.beginModelRequest(
            .init(id: UUID(), input: "goal", requestJSON: "[]", historyTaskID: id), for: input)
        try await store.append(id.uuidString, to: input)
        try await store.finishModelRequest(input, reason: "stop")
    }
    try await store.finish(input, state: .completed)
    var context = AgentContext(agentID: .assistant, scopeID: UUID(), state: AssistantContextState())
    context.state.history = try await store.snapshot()
    for id in [taskA, taskB] {
        let request = try #require(
            context.state.history.current.turns[0].modelRequests?.first { $0.historyTaskID == id })
        context.state.history.current.taskCompressions.append(
            .init(
                taskID: id, goal: id.uuidString, status: .completed, reportedSummary: "done", failure: nil,
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
