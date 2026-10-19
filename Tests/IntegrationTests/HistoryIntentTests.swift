import ActionBindings
import Actions
import AgentBindings
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import StorageChat
import StorageCore
import StorageState
import Testing

@testable import UI

private struct HistoryPresentationModule: ToolModule {
    let definitions: [ActionBinding]
}

private struct UnusedHistoryMutation: HistoryMutationCapability {
    func startNew() async throws -> String? { throw CommunicationError.unsupportedContract }
    func summarizeArchived(_ id: String) async throws { throw CommunicationError.unsupportedContract }
    func deleteArchived(_ id: String) async throws { throw CommunicationError.unsupportedContract }
}
private func intentRuntime(
    sessionID: String, presentation: any HistoryPresentationCapability,
    mutations: any HistoryMutationCapability = UnusedHistoryMutation(),
    reads: MemoryHistoryReadRequests? = nil
) throws
    -> HistoryIntentRuntime
{
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let definition = ActionBinding(
        function: UIActions.showHistoryDefinition(handler: { invocation in
            try await UIActions.showHistory(invocation: invocation, using: presentation)
        }), protocols: [.tool], executionPolicy: .direct)
    let deletion = ActionBinding(
        function: HistoryActions.deleteDefinition(completing: { invocation in
            .value(try await HistoryActions.delete(invocation: invocation, using: mutations))
        }), protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning)
    let archive = ActionBinding(
        function: HistoryActions.startNewDefinition(completing: { invocation in
            .value(try await HistoryActions.startNew(invocation: invocation, using: mutations))
        }), protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning)
    let title = ActionBinding(
        function: HistoryActions.summarizeDefinition(completing: { invocation in
            .value(try await HistoryActions.summarize(invocation: invocation, using: mutations))
        }), protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning)
    let gateway = OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [
            HistoryPresentationModule(definitions: [definition, deletion, archive, title])
        ]),
        actions: ChannelScheduler(registry: ActionRegistry()), policy: policy, sink: { _ in })
    return try HistoryIntentRuntime(
        sessionID: sessionID, manager: manager, input: input, output: gateway,
        agent: MemoryAgent(
            sessionID: sessionID, historyReads: reads,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "memory"), scope: UUID().uuidString, state: MemoryContextState())
        ))
}

@Test(.actionCatalog) @MainActor func historyRefreshTravelsThroughBothGatewaysWithoutVoiceOrModels() async throws {
    let session = UUID().uuidString
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
    func showHistory(invocation: any FunctionInput) async throws {
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
@Test(.actionCatalog) func historyRefreshRejectsOverlapAndJoinsCancellationBeforeRetry() async throws {
    let endpoint = HeldHistoryPresentation()
    let runtime = try intentRuntime(sessionID: UUID().uuidString, presentation: endpoint)
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

@Test(.actionCatalog) func memoryAgentRejectsUnknownIntentsAndBoundsPendingOutputs() async throws {
    let session = UUID().uuidString
    let agent = try MemoryAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "memory"), scope: UUID().uuidString, state: MemoryContextState())
    )
    try await agent.start()
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString,
                sessionID: session, payload: .event("history.delete"),
                metadata: InputMetadata(
                    payload: .event("history.delete"), source: "user", rootID: UUID().uuidString)))
    }
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(MemoryHistoryIntent.refresh.input(sessionID: UUID().uuidString))
    }
    for _ in 0..<256 { try await agent.receive(MemoryHistoryIntent.refresh.input(sessionID: session)) }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(MemoryHistoryIntent.refresh.input(sessionID: session))
    }
    #expect(await agent.status().lifecycle == .failed)
    await agent.stop()
}

@Test(.actionCatalog) @MainActor func historyPresentationRejectsForeignScopeWithoutChangingState() async throws {
    let state = ConversationHistoryState()
    let adapter = HistoryPresentationAdapter(
        state: state, store: ConversationHistoryStore(), sessionID: UUID().uuidString)
    let invocation = ActionInvocation(
        call: ToolRequest(id: UUID().uuidString, toolPath: "UI.HistoryPresentation.showHistory"),
        context: ActionExecutionContext(
            source: "assistant", sessionID: UUID().uuidString, inputID: UUID().uuidString))
    await #expect(throws: (any Error).self) { try await adapter.showHistory(invocation: invocation) }
    #expect(state.archive == nil)
}

private func archivedHistory(_ store: ConversationHistoryStore) async throws -> String {
    let read = try await store.readCurrent()
    let turn = UUID().uuidString
    _ = try await store.begin(id: turn, user: "archive", request: [], expecting: read.token, model: "fixture")
    try await store.finish(turn, state: .completed)
    return try #require(await store.startNew()).id
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func historyDeleteUsesCorrelatedRuntimeResultBeforePresentation() async throws {
    let store = ConversationHistoryStore()
    let id = try await archivedHistory(store)
    let session = UUID().uuidString
    let state = ConversationHistoryState()
    let runtime = try intentRuntime(
        sessionID: session,
        presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session),
        mutations: HistoryMutationService(store: store, summarizeTitle: { _ in "Unused fixture title" }))
    try await runtime.refresh()
    #expect(state.archive?.past.count == 1)
    try await runtime.deleteArchived(id)
    #expect(try await store.snapshot().past.isEmpty)
    #expect(state.archive?.past.isEmpty == true)
    #expect(await runtime.agent.status().processedInputs == 3)
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func historyDeleteRejectsCurrentAndMissingIDsAndAllowsRefreshAfterFailure()
    async throws
{
    let store = ConversationHistoryStore()
    let session = UUID().uuidString
    let state = ConversationHistoryState()
    let runtime = try intentRuntime(
        sessionID: session,
        presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session),
        mutations: HistoryMutationService(store: store, summarizeTitle: { _ in "Unused fixture title" }))
    let currentID = try await store.snapshot().current.id
    await #expect(throws: HistoryIntentFailure.self) { try await runtime.deleteArchived(currentID) }
    #expect(state.archive == nil)
    await #expect(throws: HistoryIntentFailure.self) { try await runtime.deleteArchived(UUID().uuidString) }
    try await runtime.refresh()
    #expect(state.archive?.current.id == currentID)
}

private actor HeldHistoryMutation: HistoryMutationCapability {
    nonisolated let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    nonisolated let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private let mutations: HistoryMutationService
    private var release: CheckedContinuation<Void, Never>?
    init(store: ConversationHistoryStore) {
        mutations = HistoryMutationService(store: store, summarizeTitle: { _ in "Unused fixture title" })
    }
    func startNew() async throws -> String? { try await mutations.startNew() }
    func summarizeArchived(_ id: String) async throws { try await mutations.summarizeArchived(id) }
    func deleteArchived(_ id: String) async throws {
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
@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func historyDeleteCancellationJoinsCleanupWithoutRollingBackCommittedData()
    async throws
{
    let store = ConversationHistoryStore()
    let id = try await archivedHistory(store)
    let session = UUID().uuidString
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

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func memoryDeleteRejectsUncorrelatedOrForeignFeedbackAndOverlappingIntent() async throws {
    let session = UUID().uuidString
    let agent = try MemoryAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "memory"), scope: UUID().uuidString, state: MemoryContextState())
    )
    try await agent.start()
    try await agent.receive(MemoryHistoryIntent.delete(UUID().uuidString).input(sessionID: session))
    var reader = agent.outputs.makeAsyncIterator()
    let envelope = try #require(await reader.next())
    guard case .toolCall(let call) = envelope.output else {
        Issue.record("Expected delete ToolCall")
        return
    }
    let cancelPayload = InputPayload.event("history.cancel:" + envelope.inputID)
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                id: envelope.inputID, sessionID: session, payload: cancelPayload,
                metadata: InputMetadata(payload: cancelPayload, source: "user", rootID: UUID().uuidString)))
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(MemoryHistoryIntent.refresh.input(sessionID: session))
    }
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString, sessionID: session,
                payload: .toolResult(.init(callID: UUID().uuidString, value: "ok"))))
    }
    let payload = InputPayload.toolResult(.init(callID: call.id, value: "ok"))
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString, sessionID: session, payload: payload,
                metadata: InputMetadata(payload: payload, source: "user", rootID: UUID().uuidString)))
    }
    try await agent.receive(AgentInput(id: UUID().uuidString, sessionID: session, payload: payload))
    let followup = try #require(await reader.next())
    #expect(followup.inputID == envelope.inputID)
    guard case .toolCall(let presentation) = followup.output else {
        Issue.record("Expected presentation")
        return
    }
    #expect(presentation.toolPath == "UI.HistoryPresentation.showHistory")
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(AgentInput(id: UUID().uuidString, sessionID: session, payload: payload))
    }
    await agent.stop()
}

@Test(.actionCatalog) func typedHistorySchemaRejectsForeignContentAndLegacyStringIntent() async throws {
    let contracts = try AgentContracts.communication
    let invalid = AgentMessage(
        contract: MemoryHistoryIntent.contract, content: "history.refresh", validate: { _ in })
    #expect(throws: CommunicationError.invalidPayload) { try contracts.validatedSize(invalid) }
    let session = UUID().uuidString
    let agent = try MemoryAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "memory"), scope: UUID().uuidString, state: MemoryContextState())
    )
    try await agent.start()
    let payload = InputPayload.event("history.refresh")
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString,
                sessionID: session, payload: payload,
                metadata: .init(payload: payload, source: "user", rootID: UUID().uuidString)))
    }
    await agent.stop()
}

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
    let id = UUID().uuidString
    let read = try await store.readCurrent()
    _ = try await store.begin(
        id: id, user: "原始用户输入", request: [.init(role: .user, content: "原始用户输入")],
        expecting: read.token, model: "test-model")
    try await store.append("<wait>原始模型输出</wait>", to: id)
    try await store.finish(id, state: .completed, reason: "stop")
    return store
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func archiveCommitsAndReturnsBeforeRootTitleCompletes() async throws {
    let store = try await completedConversation()
    let state = ConversationHistoryState()
    let chat = ControlledTitle()
    let session = UUID().uuidString
    let mutations = HistoryMutationService(
        store: store, summarizeTitle: { try await ConversationTitleGenerator.summarize($0, using: chat) })
    let runtime = try intentRuntime(
        sessionID: session, presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session),
        mutations: mutations)
    var started = chat.started.stream.makeAsyncIterator()
    try await runtime.startNew()
    await started.next()
    let during = try await store.snapshot()
    let archived = try #require(during.past.first)
    #expect(during.current.turns.isEmpty && archived.summaryTitle == nil)
    // A new user input and another history refresh proceed while the title model is held.
    let fresh = try await store.readCurrent()
    _ = try await store.begin(
        id: UUID().uuidString, user: "new user", request: [], expecting: fresh.token, model: "fixture")
    try await runtime.refresh()
    try await chat.finish("对话标题")
    await mutations.waitForTitles()
    #expect(try await store.conversation(archived.id).summaryTitle == "对话标题")
    await mutations.shutdown()
    await runtime.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func rootShutdownCancelsTitleAndPreservesArchiveRetryState() async throws {
    let store = try await completedConversation()
    let chat = ControlledTitle()
    let mutations = HistoryMutationService(
        store: store, summarizeTitle: { try await ConversationTitleGenerator.summarize($0, using: chat) })
    var started = chat.started.stream.makeAsyncIterator()
    let id = try #require(try await mutations.startNew())
    await started.next()
    await mutations.shutdown()
    let archived = try await store.conversation(id)
    #expect(archived.summaryTitle == nil && archived.titleError != nil)
    #expect(archived.turns.first?.user == "原始用户输入")
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func emptyHistoryArchiveDoesNotInferOrReplaceCurrentConversation()
    async throws
{
    let store = ConversationHistoryStore()
    let current = try await store.snapshot().current.id
    let state = ConversationHistoryState()
    let session = UUID().uuidString
    let runtime = try intentRuntime(
        sessionID: session, presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session),
        mutations: HistoryMutationService(
            store: store,
            summarizeTitle: { _ in
                Issue.record("Empty history must not infer a title")
                return "Unexpected"
            }))
    try await runtime.startNew()
    #expect(state.archive?.current.id == current)
    #expect(state.archive?.past.isEmpty == true)
    try await runtime.refresh()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor func titleFailureRefreshesRetryStateAndAllowsNewAttempt()
    async throws
{
    let store = ConversationHistoryStore()
    let id = try await archivedHistory(store)
    let state = ConversationHistoryState()
    let chat = ControlledTitle()
    let session = UUID().uuidString
    let runtime = try intentRuntime(
        sessionID: session, presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session),
        mutations: HistoryMutationService(
            store: store, summarizeTitle: { try await ConversationTitleGenerator.summarize($0, using: chat) }))
    var started = chat.started.stream.makeAsyncIterator()
    let first = Task { try await runtime.summarize(id) }
    await started.next()
    try await chat.finish("<express emotion=\"happy\"/>")
    await #expect(throws: HistoryIntentFailure.self) { try await first.value }
    #expect(state.archive?.past.first?.summaryTitle == nil)
    #expect(state.archive?.past.first?.titleError != nil)
    let retry = Task { try await runtime.summarize(id) }
    await started.next()
    try await chat.finish("Conversation title")
    try await retry.value
    #expect(state.archive?.past.first?.summaryTitle == "Conversation title")
    #expect(state.archive?.past.first?.titleError == nil)
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func summarizeRejectsCurrentAndMissingArchivesWithoutInference() async throws {
    let store = ConversationHistoryStore()
    let session = UUID().uuidString
    let state = ConversationHistoryState()
    let runtime = try intentRuntime(
        sessionID: session, presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session),
        mutations: HistoryMutationService(
            store: store,
            summarizeTitle: { _ in
                Issue.record("Invalid archive must not infer a title")
                return "Unexpected"
            }))
    let current = try await store.snapshot().current.id
    await #expect(throws: HistoryIntentFailure.self) { try await runtime.summarize(current) }
    await #expect(throws: HistoryIntentFailure.self) { try await runtime.summarize(UUID().uuidString) }
    try await runtime.refresh()
    #expect(state.archive?.current.id == current && state.archive?.past.isEmpty == true)
}

private struct FailedArchivePresentation: HistoryPresentationCapability {
    func showHistory(invocation: any FunctionInput) async throws { throw CommunicationError.scopeClosed }
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) func archivePresentationFailureDoesNotCancelRootTitle() async throws {
    let store = try await completedConversation()
    let old = try await store.snapshot().current.id
    let mutations = HistoryMutationService(store: store, summarizeTitle: { _ in "Completed title" })
    let runtime = try intentRuntime(
        sessionID: UUID().uuidString, presentation: FailedArchivePresentation(), mutations: mutations)
    await #expect(throws: HistoryIntentFailure.self) { try await runtime.startNew() }
    await mutations.waitForTitles()
    let snapshot = try await store.snapshot()
    #expect(snapshot.current.id != old && snapshot.past.first?.id == old)
    #expect(snapshot.past.first?.summaryTitle == "Completed title")
    await mutations.shutdown()
    await runtime.shutdown()
}

@Test(.actionCatalog) func memoryAndPhotographerHaveCanonicalIndependentRoleIdentities() throws {
    let memory = try AgentConfigurations.load(named: "Memory")
    let photographer = try AgentConfigurations.load(named: "Photographer")
    #expect(memory.agentID == .memory)
    #expect(photographer.agentID == .photographer)
    #expect(
        try MemoryAgent(
            sessionID: UUID().uuidString,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "memory"), scope: UUID().uuidString, state: MemoryContextState())
        ).descriptor.name == "Memory")
    #expect(
        try PhotographerAgent(
            sessionID: UUID().uuidString,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        ).descriptor.name == "Photographer")
    #expect(throws: AgentConfigurationError.identityMismatch) {
        try MemoryAgent(
            sessionID: UUID().uuidString, configuration: photographer,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "memory"), scope: UUID().uuidString, state: MemoryContextState())
        )
    }
    #expect(throws: AgentConfigurationError.identityMismatch) {
        try PhotographerAgent(
            sessionID: UUID().uuidString, configuration: memory,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
    }
}

@Test(.actionCatalog) func memoryOverflowRetainsAcceptedOutputsAndFailsOnlyItsActor() async throws {
    let session = UUID().uuidString
    let memory = try MemoryAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "memory"), scope: UUID().uuidString, state: MemoryContextState())
    )
    let photographer = try PhotographerAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
    )
    try await memory.start()
    try await photographer.start()
    var accepted: [String] = []
    for _ in 0..<256 {
        let input = try MemoryHistoryIntent.refresh.input(sessionID: session)
        accepted.append(input.id)
        try await memory.receive(input)
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await memory.receive(MemoryHistoryIntent.refresh.input(sessionID: session))
    }
    #expect(await memory.status().lifecycle == .failed)
    #expect(await memory.status().processedInputs == 256)
    #expect(await photographer.status().lifecycle == .running)
    var retained: [String] = []
    for await envelope in memory.outputs {
        #expect(envelope.source == .memory)
        retained.append(envelope.inputID)
    }
    #expect(retained == accepted)
    await photographer.stop()
}

@Test(.actionCatalog) @MainActor func taskDialogueRemainsVisibleAndNewConversationPreservesItsEvidence() async throws {
    let session = UUID().uuidString
    let repository = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let store = AgentChatHistoryContext.store(repository: repository)
    let agent = try AssistantAgent(stateContext: try publicStateFixture(), conversations: store, context: repository)
    try await agent.start()
    let input = UUID().uuidString
    _ = try await agent.controlTask(
        "startTask", arguments: ["goal": "拍照并等待保存", "skills": "[\"photography\"]"],
        source: "assistant", sessionID: session, inputID: input, decisionID: nil)
    let read = try await store.readCurrent()
    _ = try await store.begin(id: input, user: "帮我拍照", request: [], expecting: read.token, model: "fixture")
    let historyTaskID = try #require(try await repository.snapshot().state.skillState?.activeTaskID)
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "帮我拍照", requestJSON: "[]", historyTaskID: historyTaskID),
        for: input)
    try await store.append("照片已拍摄，要保存吗？", to: input)
    try await store.finish(input, state: .completed)
    let state = ConversationHistoryState()
    let adapter = HistoryPresentationAdapter(state: state, store: store, sessionID: session)
    let invocation = ActionInvocation(
        call: ToolRequest(id: UUID().uuidString, toolPath: "UI.HistoryPresentation.showHistory"),
        context: ActionExecutionContext(source: "memory", sessionID: session, inputID: UUID().uuidString))
    try await adapter.showHistory(invocation: invocation)
    #expect(state.archive?.current.turns.isEmpty == true && state.archive?.current.turnCount == 1)
    #expect(state.archive?.current.latestUser == "帮我拍照")
    let currentRecords = try HistoryPresentationAdapter.conversation((try await store.snapshot()).current)
    #expect(
        ConversationHistoryPresentation.turns(currentRecords).filter { $0.historyTaskID == historyTaskID }
            .count == 1)
    _ = try await agent.controlTask(
        "cancelTask", arguments: ["reason": "用户开始新对话"], source: "assistant", sessionID: session,
        inputID: UUID().uuidString, decisionID: nil)
    let archived = try #require(try await store.startNew())
    #expect(archived.turns.first?.id == input)
    #expect(archived.taskCompressions.first?.taskID == historyTaskID)
    #expect(archived.taskCompressions.first?.status == .cancelled)
    #expect(try await repository.snapshot().state.skillState?.tasks.isEmpty == true)
    let archivedRecords = try HistoryPresentationAdapter.conversation(try await store.conversation(archived.id))
    let archivedItems = ConversationHistoryPresentation.timeline(archivedRecords)
    guard case .task(let savedTask, let sources) = try #require(archivedItems.first) else {
        Issue.record("Archived conversation must retain cancelled Task and full request source")
        return
    }
    #expect(savedTask.taskID == historyTaskID && savedTask.status == .cancelled)
    #expect(sources.count == 1 && sources[0].raw == "照片已拍摄，要保存吗？")
    try await adapter.showHistory(invocation: invocation)
    #expect(state.archive?.current.turns.isEmpty == true)
    #expect(state.archive?.past.first?.turns.isEmpty == true)
    #expect(try await store.conversation(archived.id).turns.first?.raw == "照片已拍摄，要保存吗？")
    await agent.stop()
}

@Test(.actionCatalog) @MainActor func historyReadQueryIsAdmittedByMemoryWithoutPresentationOrModel() async throws {
    let store = ConversationHistoryStore()
    let current = try await store.readCurrent()
    let reads = MemoryHistoryReadRequests { query in
        guard case .conversation(let id) = query else { throw CommunicationError.invalidPayload }
        return .conversation(try await store.page(id))
    }
    let state = ConversationHistoryState()
    let session = UUID().uuidString
    let runtime = try intentRuntime(
        sessionID: session,
        presentation: HistoryPresentationAdapter(state: state, store: store, sessionID: session), reads: reads)
    let result = try await runtime.query(.conversation(current.current.id))
    guard case .conversation(let value) = result else {
        Issue.record("Expected conversation")
        return
    }
    #expect(value.id == current.current.id)
    #expect(state.archive == nil)
    #expect(await runtime.agent.status().processedInputs == 1)
    await runtime.shutdown()
}

@Test(.actionCatalog) func historyReadStagingRejectsOverflowAndWrongSessionWithoutReading() async throws {
    let reads = MemoryHistoryReadRequests { _ in .photo(nil) }
    let session = UUID().uuidString
    var ids: [String] = []
    for _ in 0..<4 { ids.append(try await reads.stage(.photo(id: "media_1", inputID: "input"), sessionID: session)) }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await reads.stage(.archives(before: 10), sessionID: session)
    }
    await #expect(throws: CommunicationError.scopeClosed) {
        try await reads.execute(ids[0], sessionID: UUID().uuidString)
    }
    for id in ids { await reads.discard(id) }
    let id = try await reads.stage(.archives(before: 10), sessionID: session)
    await reads.discard(id)
    await reads.shutdown()
    await #expect(throws: CommunicationError.scopeClosed) {
        try await reads.stage(.archives(before: 10), sessionID: session)
    }
}

@Test(.actionCatalog) @MainActor func historyReadCancellationJoinsActualReaderAndReleasesAdmission() async throws {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let reads = MemoryHistoryReadRequests { _ in
        try await withTaskCancellationHandler {
            entered.continuation.yield(())
            for await _ in release.stream { break }
            try Task.checkCancellation()
            return .photo(nil)
        } onCancel: {
            cancelled.continuation.yield(())
        }
    }
    let store = ConversationHistoryStore()
    let session = UUID().uuidString
    let runtime = try intentRuntime(
        sessionID: session,
        presentation: HistoryPresentationAdapter(state: ConversationHistoryState(), store: store, sessionID: session),
        reads: reads)
    let operation = Task { try await runtime.query(.photo(id: "media_1", inputID: "input")) }
    for await _ in entered.stream { break }
    operation.cancel()
    for await _ in cancelled.stream { break }
    release.continuation.yield(())
    await #expect(throws: CancellationError.self) { try await operation.value }
    let next = try await reads.stage(.archives(before: 10), sessionID: session)
    await reads.discard(next)
    await runtime.shutdown()
}

private enum HistoryReadFixtureFailure: Error, Equatable { case unavailable }

@Test(.actionCatalog) @MainActor func historyReadFailurePreservesProducerAndDoesNotPresent() async throws {
    let reads = MemoryHistoryReadRequests { _ in throw HistoryReadFixtureFailure.unavailable }
    let state = ConversationHistoryState()
    let session = UUID().uuidString
    let runtime = try intentRuntime(
        sessionID: session,
        presentation: HistoryPresentationAdapter(state: state, store: ConversationHistoryStore(), sessionID: session),
        reads: reads)
    await #expect(throws: HistoryReadFixtureFailure.unavailable) { try await runtime.query(.archives(before: 10)) }
    #expect(state.archive == nil)
    let next = try await reads.stage(.archives(before: 10), sessionID: session)
    await reads.discard(next)
    await runtime.shutdown()
}
