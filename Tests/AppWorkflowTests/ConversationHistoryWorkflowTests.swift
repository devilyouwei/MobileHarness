import AgentCore
import Agents
import AppWorkflows
import Foundation
import StorageChat
import Testing
import UI

@Test @MainActor func assistantHistoryGroupsForegroundAndBackgroundTasksByPersistedIdentity() async throws {
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
    let background = AgentTaskScope(
        requester: .assistant, executor: .photographer, sessionID: UUID(), execution: .background)
    try context.tasks.register(background)
    context.state.taskViews = [
        background.id: AgentTaskView(scope: background, content: try AgentTaskContent(text: "后台拍摄"))
    ]
    let snapshot = try HistoryPresentationAdapter.assistantTasks(context)
    #expect(snapshot.tasks.count == 2)
    let photo = try #require(snapshot.tasks.first { $0.id == foreground })
    #expect(photo.title == "帮我拍照" && photo.execution == "foreground" && photo.executor == "assistant")
    #expect(photo.turns.count == 2 && photo.turns[1].isReACT == true)
    #expect(Set(photo.turns.compactMap(\.ownerInputID)) == [input])
    let delegated = try #require(snapshot.tasks.first { $0.id == background.id })
    #expect(delegated.execution == "background" && delegated.executor == "photographer" && delegated.turns.isEmpty)
    #expect(snapshot.archive.past.count == 1)
    #expect(photo.compression?.sources.count == 2)
    context.state.skillState?.tasks = []
    let retired = try HistoryPresentationAdapter.assistantTasks(context)
    #expect(retired.tasks.first(where: { $0.id == foreground })?.turns.count == 2)
}

@Test @MainActor func failedHistoryLoadDoesNotCreateAnEphemeralStore() async {
    let state = ConversationHistoryState()
    let workflow = ConversationHistoryWorkflow(
        state: state, prepare: { throw CancellationError() },
        refresh: { Issue.record("Must not refresh after failed preparation") },
        deleteArchive: { _ in Issue.record("Must not delete after failed preparation") },
        startNew: { Issue.record("Must not archive after failed preparation") },
        summarize: { _ in Issue.record("Must not summarize after failed preparation") }, previewOutput: { _ in "" },
        readPhoto: { _, _ in nil })
    await workflow.load()
    workflow.startNew()
    #expect(state.archive == nil && state.status != nil && !state.isBusy)
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
        }, summarize: { summaries.append($0) }, previewOutput: { _ in "" }, readPhoto: { _, _ in nil })
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
        previewOutput: { _ in "" }, readPhoto: read)
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

@Test @MainActor func taskHistoryDestinationKeepsStateAndMutationAuthoritySeparate() async {
    let first = ConversationHistoryState(title: "Assistant")
    let second = ConversationHistoryState(title: "任务记录", allowsMutations: false)
    var reads = 0
    var mutations = 0
    let workflow = ConversationHistoryWorkflow(
        state: second, prepare: {},
        refresh: {
            reads += 1
            second.archive = HistorySnapshot()
        },
        deleteArchive: { _ in mutations += 1 }, startNew: { mutations += 1 },
        summarize: { _ in mutations += 1 }, previewOutput: { _ in "photo preview" }, readPhoto: { _, _ in nil })
    let destination = HistoryAgentDestination(
        id: "assistant.tasks", name: "任务记录", summary: "任务", state: second, controls: workflow)
    await destination.controls.load()
    destination.controls.startNew()
    destination.controls.delete(UUID())
    destination.controls.summarize(UUID())
    await workflow.waitUntilIdle()
    #expect(reads == 1 && mutations == 0)
    #expect(first.archive == nil && second.archive != nil)
    #expect(destination.state.title == "任务记录")
}

@Test @MainActor func failedTaskHistoryReadPreservesAssistantSnapshot() async {
    let assistant = ConversationHistoryState(title: "Assistant")
    assistant.archive = HistorySnapshot()
    let specialist = ConversationHistoryState(title: "任务记录", allowsMutations: false)
    let workflow = ConversationHistoryWorkflow(
        state: specialist, prepare: {}, refresh: { throw HistoryPhotoFixtureError.failed },
        deleteArchive: { _ in }, startNew: {}, summarize: { _ in }, previewOutput: { _ in "" },
        readPhoto: { _, _ in nil })
    await workflow.load()
    #expect(specialist.archive == nil && specialist.status != nil)
    #expect(assistant.archive != nil && assistant.status == nil)
}

@Test @MainActor func taskHistorySeparatesTwoTasksWithinOneInput() async throws {
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
    let snapshot = try HistoryPresentationAdapter.assistantTasks(context)
    #expect(snapshot.tasks.count == 2)
    for task in snapshot.tasks {
        #expect(task.turns.count == 1 && task.turns[0].historyTaskID == task.id)
    }
    let items = ConversationHistoryPresentation.timeline(snapshot.archive.current)
    #expect(items.count == 2 && Set(items.map(\.id)) == [taskA, taskB])
    for item in items {
        guard case .task(let compression, let sources) = item else {
            Issue.record("Expected expandable Task compression")
            continue
        }
        #expect(sources.count == 1 && sources[0].id == compression.sources[0].requestID)
    }
}
