import ActionRuntime
import AgentCore
import Agents
import AppWorkflows
import Foundation
import Gateway
import StorageChat
import Testing
import ToolRuntime
import Tools
import UI

private struct HistoryPresentationModule: ToolModule {
    let definitions: [ToolDefinition]
}

private struct UnusedHistoryMutation: HistoryMutationCapability {
    func deleteArchived(_ id: UUID) async throws { throw CommunicationError.unsupportedContract }
}
private func intentRuntime(
    sessionID: UUID, presentation: any HistoryPresentationCapability,
    mutations: any HistoryMutationCapability = UnusedHistoryMutation()
) throws
    -> HistoryIntentRuntime
{
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["user", "runtime"],
        configurations: [AgentConfigurations.load(named: "ConversationMemory")])
    let input = InputGateway(manager: manager, policy: policy)
    let definition = UITools.showHistoryDefinition(completing: { call, context in
        try await UITools.showHistory(invocation: ToolInvocation(call: call, context: context), using: presentation)
    })
    let deletion = HistoryTools.deleteDefinition(handler: { call in
        try await HistoryTools.delete(call: call, using: mutations)
    })
    let gateway = OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [HistoryPresentationModule(definitions: [definition, deletion])]),
        actions: ChannelScheduler(registry: ActionRegistry()), policy: policy, sink: { _ in })
    return try HistoryIntentRuntime(
        sessionID: sessionID, manager: manager, input: input, output: gateway,
        agent: ConversationMemoryAgent(sessionID: sessionID))
}

@Test @MainActor func historyRefreshTravelsThroughBothGatewaysWithoutVoiceOrModels() async throws {
    let session = UUID()
    let store = ConversationHistoryStore()
    let state = ConversationHistoryState()
    let runtime = try intentRuntime(
        sessionID: session, presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session))
    #expect(state.archive == nil)
    try await runtime.refresh()
    #expect(state.archive?.current.id == (try await store.snapshot()).current.id)
    #expect(await runtime.agent.status().processedInputs == 1)
    try await runtime.refresh()
    #expect(await runtime.agent.status().processedInputs == 2)
}

private actor HeldHistoryPresentation: HistoryPresentationCapability {
    nonisolated let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    nonisolated let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var release: CheckedContinuation<Void, Never>?
    private var held = true
    var completed = 0
    func showHistory(invocation: ToolInvocation) async throws {
        if held {
            held = false
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    release = $0
                    started.continuation.yield(())
                }
            } onCancel: {
                self.cancelled.continuation.yield(())
            }
        }
        try Task.checkCancellation()
        completed += 1
    }
    func finish() {
        release?.resume()
        release = nil
    }
}
@Test func historyRefreshRejectsOverlapAndJoinsCancellationBeforeRetry() async throws {
    let endpoint = HeldHistoryPresentation()
    let runtime = try intentRuntime(sessionID: UUID(), presentation: endpoint)
    var started = endpoint.started.stream.makeAsyncIterator()
    let first = Task { try await runtime.refresh() }
    await started.next()
    await #expect(throws: CommunicationError.capacityExceeded) { try await runtime.refresh() }
    var cancelled = endpoint.cancelled.stream.makeAsyncIterator()
    first.cancel()
    await cancelled.next()
    await endpoint.finish()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(await endpoint.completed == 0)
    try await runtime.refresh()
    #expect(await endpoint.completed == 1)
    #expect(await runtime.agent.status().lifecycle == .running)
}

@Test func memoryAgentRejectsUnknownIntentsAndBoundsPendingOutputs() async throws {
    let session = UUID()
    let agent = try ConversationMemoryAgent(sessionID: session)
    try await agent.start()
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                sessionID: session, payload: .event("history.delete"),
                metadata: InputMetadata(payload: .event("history.delete"), source: "user")))
    }
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(ConversationMemoryIntent.refresh.input(sessionID: UUID()))
    }
    for _ in 0..<8 { try await agent.receive(ConversationMemoryIntent.refresh.input(sessionID: session)) }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(ConversationMemoryIntent.refresh.input(sessionID: session))
    }
    #expect(await agent.status().lifecycle == .failed)
    await agent.stop()
}

@Test @MainActor func historyPresentationRejectsForeignScopeWithoutChangingState() async throws {
    let state = ConversationHistoryState()
    let adapter = HistoryPresentationAdapter(state: state, store: ConversationHistoryStore(), sessionID: UUID())
    let invocation = ToolInvocation(
        call: ToolRequest(toolPath: "UI.showHistory"),
        context: ToolExecutionContext(source: "assistant", sessionID: UUID(), inputID: UUID()))
    await #expect(throws: (any Error).self) { try await adapter.showHistory(invocation: invocation) }
    #expect(state.archive == nil)
}

private func archivedHistory(_ store: ConversationHistoryStore) async throws -> UUID {
    let read = try await store.readCurrent()
    let turn = UUID()
    _ = try await store.begin(id: turn, user: "archive", request: [], expecting: read.token, model: "fixture")
    try await store.finish(turn, state: .completed)
    return try #require(await store.startNew()).id
}

@Test(.timeLimit(.minutes(1))) @MainActor func historyDeleteUsesCorrelatedRuntimeResultBeforePresentation() async throws
{
    let store = ConversationHistoryStore()
    let id = try await archivedHistory(store)
    let session = UUID()
    let state = ConversationHistoryState()
    let runtime = try intentRuntime(
        sessionID: session,
        presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session),
        mutations: HistoryMutationService(store: store))
    try await runtime.refresh()
    #expect(state.archive?.past.count == 1)
    try await runtime.deleteArchived(id)
    #expect(try await store.snapshot().past.isEmpty)
    #expect(state.archive?.past.isEmpty == true)
    #expect(await runtime.agent.status().processedInputs == 3)
}

@Test(.timeLimit(.minutes(1))) @MainActor func historyDeleteRejectsCurrentAndMissingIDsAndAllowsRefreshAfterFailure()
    async throws
{
    let store = ConversationHistoryStore()
    let session = UUID()
    let state = ConversationHistoryState()
    let runtime = try intentRuntime(
        sessionID: session,
        presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session),
        mutations: HistoryMutationService(store: store))
    let currentID = try await store.snapshot().current.id
    await #expect(throws: HistoryIntentFailure.self) { try await runtime.deleteArchived(currentID) }
    #expect(state.archive == nil)
    await #expect(throws: HistoryIntentFailure.self) { try await runtime.deleteArchived(UUID()) }
    try await runtime.refresh()
    #expect(state.archive?.current.id == currentID)
}

private actor HeldHistoryMutation: HistoryMutationCapability {
    nonisolated let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    nonisolated let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private let mutations: HistoryMutationService
    private var release: CheckedContinuation<Void, Never>?
    init(store: ConversationHistoryStore) { mutations = HistoryMutationService(store: store) }
    func deleteArchived(_ id: UUID) async throws {
        try await mutations.deleteArchived(id)
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                release = $0
                started.continuation.yield(())
            }
        } onCancel: {
            self.cancelled.continuation.yield(())
        }
        try Task.checkCancellation()
    }
    func finish() {
        release?.resume()
        release = nil
    }
}
@Test(.timeLimit(.minutes(1))) @MainActor func historyDeleteCancellationJoinsCleanupWithoutRollingBackCommittedData()
    async throws
{
    let store = ConversationHistoryStore()
    let id = try await archivedHistory(store)
    let session = UUID()
    let state = ConversationHistoryState()
    let mutation = HeldHistoryMutation(store: store)
    let runtime = try intentRuntime(
        sessionID: session,
        presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session), mutations: mutation)
    try await runtime.refresh()
    var started = mutation.started.stream.makeAsyncIterator()
    var cancelled = mutation.cancelled.stream.makeAsyncIterator()
    let deletion = Task { try await runtime.deleteArchived(id) }
    await started.next()
    deletion.cancel()
    await cancelled.next()
    await #expect(throws: CommunicationError.capacityExceeded) { try await runtime.refresh() }
    #expect(state.archive?.past.count == 1)
    #expect(try await store.snapshot().past.isEmpty)
    await mutation.finish()
    await #expect(throws: CancellationError.self) { try await deletion.value }
    try await runtime.refresh()
    #expect(state.archive?.past.isEmpty == true)
}

@Test(.timeLimit(.minutes(1))) func memoryDeleteRejectsUncorrelatedOrForeignFeedbackAndOverlappingIntent() async throws
{
    let session = UUID()
    let agent = try ConversationMemoryAgent(sessionID: session)
    try await agent.start()
    try await agent.receive(ConversationMemoryIntent.delete(UUID()).input(sessionID: session))
    var reader = agent.outputs.makeAsyncIterator()
    let envelope = try #require(await reader.next())
    guard case .toolCall(let call) = envelope.output else {
        Issue.record("Expected delete ToolCall")
        return
    }
    let cancelPayload = InputPayload.event("history.cancel:" + envelope.inputID.uuidString)
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                id: envelope.inputID, sessionID: session, payload: cancelPayload,
                metadata: InputMetadata(payload: cancelPayload, source: "user")))
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(ConversationMemoryIntent.refresh.input(sessionID: session))
    }
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(sessionID: session, payload: .toolResult(.init(callID: UUID(), value: "ok"))))
    }
    let payload = InputPayload.toolResult(.init(callID: call.id, value: "ok"))
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(sessionID: session, payload: payload, metadata: InputMetadata(payload: payload, source: "user")))
    }
    try await agent.receive(AgentInput(sessionID: session, payload: payload))
    let followup = try #require(await reader.next())
    #expect(followup.inputID == envelope.inputID)
    guard case .toolCall(let presentation) = followup.output else {
        Issue.record("Expected presentation")
        return
    }
    #expect(presentation.toolPath == "UI.showHistory")
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(AgentInput(sessionID: session, payload: payload))
    }
    await agent.stop()
}
