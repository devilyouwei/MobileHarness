import AgentCore
import Agents
import AppWorkflows
import Foundation
import StorageChat
import Testing
import UI

@Test @MainActor func specialistHistoryGroupsInputsAndReACTByTaskWithoutArchiveSummaries() async throws {
    let session = UUID()
    let scope = AgentTaskScope(requester: .assistant, executor: .photographer, sessionID: session)
    let other = AgentTaskScope(requester: .assistant, executor: .photographer, sessionID: session)
    let store = ConversationHistoryStore()
    var context = AgentContext(agentID: .photographer, scopeID: session, state: PhotographerContextState())
    try context.tasks.register(scope)
    try context.tasks.register(other)
    context.state.taskViews = [
        scope.id: AgentTaskView(
            scope: scope, content: try AgentTaskContent(text: "照片已保存", stage: .completed), terminal: true),
        other.id: AgentTaskView(
            scope: other, content: try AgentTaskContent(text: "另一任务", stage: .waitingUser, interactionID: UUID())),
    ]
    try context.tasks.report(
        try AgentTaskContent(text: "照片已保存").signal(.result, scope: scope, status: .succeeded), agent: .photographer)
    let ids = [UUID(), UUID(), UUID(), UUID()]
    for (index, id) in ids.enumerated() {
        let read = try await store.readCurrent()
        _ = try await store.begin(
            id: id, user: ["帮我拍照", "另一任务", "保存照片", "旧记录"][index], request: [], expecting: read.token, model: "fixture")
        try await store.beginModelRequest(ConversationModelRequest(id: UUID(), input: "输入", requestJSON: "[]"), for: id)
        try await store.append("回复", to: id)
        try await store.finishModelRequest(id, reason: "stop")
        if index == 0 {
            try await store.beginModelRequest(
                ConversationModelRequest(id: UUID(), input: "拍照结果", requestJSON: "[]"), for: id)
            try await store.append("是否保存", to: id)
            try await store.finishModelRequest(id, reason: "stop")
        }
        try await store.finish(id, state: .completed)
        if index < 3 {
            let task = index == 1 ? other : scope
            let signal = try AgentTaskContent(text: index == 0 ? "帮我拍照" : "补充输入").signal(
                index == 2 ? .input : .request, scope: task)
            let input = try AgentInput(
                id: id, sessionID: session, payload: .observation(signal.message()), taskScope: task)
            try context.append(
                AgentContext<PhotographerContextState>.Record(
                    taskID: index == 0 ? input.id : task.id, kind: signal.contract,
                    data: JSONEncoder().encode(SignalEvidence(input))))
        }
    }
    context.state.history = try await store.snapshot()
    var archived = context.state.history.current
    archived.turns = Array(archived.turns.prefix(2))
    context.state.history.past = [archived]
    context.state.history.current.turns = Array(context.state.history.current.turns.suffix(2))
    let snapshot = try HistoryPresentationAdapter.taskSnapshot(context)
    #expect(snapshot.tasks.count == 3)
    let photo = try #require(snapshot.tasks.first { $0.id == scope.id })
    #expect(photo.title == "帮我拍照" && photo.status == "已完成" && photo.isAssociated)
    #expect(photo.turns.count == 3 && photo.turns[1].isReACT == true)
    #expect(Set(photo.turns.compactMap(\.ownerInputID)) == [ids[0], ids[2]])
    let waiting = try #require(snapshot.tasks.first { $0.id == other.id })
    #expect(waiting.status == "等待用户" && waiting.turns.count == 1)
    let legacy = try #require(snapshot.tasks.first { $0.id == ids[3] })
    #expect(!legacy.isAssociated && legacy.title == "旧记录")
    #expect(snapshot.archive.current.turns.count == 2 && snapshot.archive.past[0].turns.count == 2)
}

@Test @MainActor func specialistHistoryRetainsTasksWithoutModelRequestsAndRecoveryStatus() throws {
    let scope = AgentTaskScope(requester: .assistant, executor: .photographer, sessionID: UUID())
    var context = AgentContext(agentID: .photographer, scopeID: scope.sessionID, state: PhotographerContextState())
    try context.tasks.register(scope)
    context.state.taskViews = [
        scope.id: AgentTaskView(
            scope: scope, content: try AgentTaskContent(text: "等待确认", stage: .waitingUser, interactionID: UUID()))
    ]
    var cancelled = context
    try cancelled.tasks.report(
        try AgentTaskContent(text: "已取消").signal(.result, scope: scope, status: .cancelled), agent: .photographer)
    #expect(try HistoryPresentationAdapter.taskSnapshot(cancelled).tasks[0].status == "已取消")
    context.tasks.recover()
    let snapshot = try HistoryPresentationAdapter.taskSnapshot(context)
    #expect(snapshot.tasks.count == 1 && snapshot.tasks[0].turns.isEmpty)
    #expect(snapshot.tasks[0].status == "已中断")
    #expect(snapshot.tasks[0].createdAt == nil)
    #expect(ConversationHistoryState().groupsByTask == false)
    #expect(ConversationHistoryState(allowsMutations: false, groupsByTask: true).groupsByTask)
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
    #expect(value.fragments == ["observed"] && value.firstTokenAt == request.date.addingTimeInterval(0.25))
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
        "version": 1, "past": [],
        "current": [
            "id": UUID().uuidString, "createdAt": 0,
            "turns": [
                [
                    "id": owner.uuidString, "date": 0, "user": "photo", "request": [], "model": "fixture",
                    "temperature": 0.7,
                    "fragments": [], "state": "completed",
                    "modelRequests": [
                        [
                            "id": round.uuidString, "date": 0, "input": "photo", "requestJSON": request,
                            "fragments": [], "toolCalls": [], "state": "completed",
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

@Test @MainActor func agentHistoryDestinationsKeepStateAndMutationAuthoritySeparate() async {
    let first = ConversationHistoryState(title: "Assistant")
    let second = ConversationHistoryState(title: "Photographer", allowsMutations: false)
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
        id: "photographer", name: "Photographer", summary: "拍摄", state: second, controls: workflow)
    await destination.controls.load()
    destination.controls.startNew()
    destination.controls.delete(UUID())
    destination.controls.summarize(UUID())
    await workflow.waitUntilIdle()
    #expect(reads == 1 && mutations == 0)
    #expect(first.archive == nil && second.archive != nil)
    #expect(destination.state.title == "Photographer")
}

@Test @MainActor func failedSpecialistHistoryReadPreservesOtherAgentSnapshot() async {
    let assistant = ConversationHistoryState(title: "Assistant")
    assistant.archive = HistorySnapshot()
    let specialist = ConversationHistoryState(title: "Memory", allowsMutations: false)
    let workflow = ConversationHistoryWorkflow(
        state: specialist, prepare: {}, refresh: { throw HistoryPhotoFixtureError.failed },
        deleteArchive: { _ in }, startNew: {}, summarize: { _ in }, previewOutput: { _ in "" },
        readPhoto: { _, _ in nil })
    await workflow.load()
    #expect(specialist.archive == nil && specialist.status != nil)
    #expect(assistant.archive != nil && assistant.status == nil)
}
