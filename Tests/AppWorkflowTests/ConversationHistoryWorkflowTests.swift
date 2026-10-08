import AppWorkflows
import Foundation
import StorageChat
import Testing
import UI

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
    try await store.recordFirstToken(at: request.date.addingTimeInterval(0.25), for: id)
    try await store.append("observed", to: id)
    try await store.finishModelRequest(id, reason: "stop")
    try await store.finish(id, state: .completed)
    let snapshot = try HistoryPresentationAdapter.presentationSnapshot(try await store.snapshot())
    let value = try #require(snapshot.current.turns.first?.modelRequests?.first)
    #expect(value.id == request.id && value.requestJSON == request.requestJSON)
    #expect(value.fragments == ["observed"] && value.firstTokenAt == request.date.addingTimeInterval(0.25))
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
