import Agents
import AppWorkflows
import Foundation
import ModelKit
import Storage
import StorageChat
import Testing
import UI

private actor ControlledTitle: ChatCapability {
    nonisolated var availability: CapabilityAvailability { .available }
    nonisolated let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var emitter: InferenceEmitter<ChatEvent>?
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        emitter = pair.emitter
        started.continuation.yield(())
        return pair.session
    }
    func finish(_ title: String) throws {
        try emitter?.yield(.text(title))
        try emitter?.yield(.finished(.stop))
        emitter?.finish()
    }
}

private func completedConversation() async throws -> ConversationHistoryStore {
    let store = ConversationHistoryStore()
    let id = UUID()
    let read = try await store.readCurrent()
    _ = try await store.begin(
        id: id, user: "原始用户输入", request: [.init(role: .user, content: "原始用户输入")],
        expecting: read.token, model: "test-model")
    try await store.append("<wait>原始模型输出</wait>", to: id)
    try await store.finish(id, state: .completed, reason: "stop")
    return store
}

@Test(.timeLimit(.minutes(1))) @MainActor
func archiveCommitsBeforeTitleAndRejectsOverlappingPageOperations() async throws {
    let store = try await completedConversation()
    let state = ConversationHistoryState()
    let chat = ControlledTitle()
    let workflow = ConversationHistoryWorkflow(
        state: state, loadStore: { store },
        summarizeTitle: { try await ConversationTitleGenerator.summarize($0, using: chat) }, previewOutput: { _ in "" })
    await workflow.load()
    let old = try #require(state.archive?.current.id)
    var started = chat.started.stream.makeAsyncIterator()
    workflow.startNew()
    await started.next()
    #expect(state.isBusy)
    let during = try await store.snapshot()
    #expect(during.current.turns.isEmpty && during.current.id != old)
    #expect(during.past.first?.id == old && during.past.first?.summaryTitle == nil)
    workflow.startNew()
    workflow.delete(old)
    try await chat.finish("对话标题")
    await workflow.waitUntilIdle()
    let finished = try await store.snapshot()
    #expect(!state.isBusy && finished.past.count == 1)
    #expect(finished.past.first?.summaryTitle == "对话标题")
    #expect(finished.past.first?.turns.first?.raw == "<wait>原始模型输出</wait>")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func leavingHistoryCancelsTitleButPreservesArchivedConversationAndSupportsRetry() async throws {
    let store = try await completedConversation()
    let chat = ControlledTitle()
    let state = ConversationHistoryState()
    let workflow = ConversationHistoryWorkflow(
        state: state, loadStore: { store },
        summarizeTitle: { try await ConversationTitleGenerator.summarize($0, using: chat) }, previewOutput: { _ in "" })
    await workflow.load()
    var started = chat.started.stream.makeAsyncIterator()
    workflow.startNew()
    await started.next()
    workflow.cancel()
    #expect(state.isBusy)  // Admission stays closed until the existing operation has cleaned up.
    await workflow.waitUntilIdle()
    let archived = try #require(try await store.snapshot().past.first)
    #expect(!state.isBusy && archived.summaryTitle == nil && archived.titleError != nil)
    #expect(archived.turns.first?.user == "原始用户输入")
    workflow.summarize(archived.id)
    await started.next()
    try await chat.finish("重新生成的标题")
    await workflow.waitUntilIdle()
    #expect(try await store.snapshot().past.first?.summaryTitle == "重新生成的标题")
}

@Test @MainActor
func failedHistoryLoadDoesNotCreateAnEphemeralStore() async {
    let state = ConversationHistoryState()
    let workflow = ConversationHistoryWorkflow(
        state: state, loadStore: { throw CancellationError() },
        summarizeTitle: { try await ConversationTitleGenerator.summarize($0, using: ControlledTitle()) },
        previewOutput: { _ in "" })
    await workflow.load()
    workflow.startNew()
    #expect(state.archive == nil && state.status != nil && !state.isBusy)
}
