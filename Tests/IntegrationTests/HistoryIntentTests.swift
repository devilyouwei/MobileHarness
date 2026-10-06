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

private func intentRuntime(sessionID: UUID, presentation: any HistoryPresentationCapability) throws
    -> HistoryIntentRuntime
{
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["user"],
        configurations: [AgentConfigurations.load(named: "ConversationMemory")])
    let input = InputGateway(manager: manager, policy: policy)
    let definition = UITools.showHistoryDefinition(completing: { call, context in
        try await UITools.showHistory(invocation: ToolInvocation(call: call, context: context), using: presentation)
    })
    let gateway = OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [HistoryPresentationModule(definitions: [definition])]),
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
