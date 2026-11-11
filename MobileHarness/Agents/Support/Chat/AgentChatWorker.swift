import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

private struct AgentChatRoundFailure: Error, CustomStringConvertible {
    let cause: any Error
    let cleanup: String
    var description: String {
        let detail = (cause as? any ChatFailureProviding)?.chatFailure.description ?? String(describing: cause)
        return "\(detail); round closure: \(cleanup)"
    }
}

/// Model-backed assistant; concrete model selection belongs exclusively to the composition root.
public actor AgentChatWorker<State: AgentChatContextState>: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    public nonisolated let skillUpdates: AsyncStream<AgentTaskSkillState>
    private let skillContinuation: AsyncStream<AgentTaskSkillState>.Continuation

    // MARK: - State and dependencies

    private(set) var speechOutput: (any AgentSpeechOutput)?
    public func bindSpeechOutput(_ value: any AgentSpeechOutput) throws {
        guard speechOutput == nil, worker == nil, lifecycle != .stopped else { throw HarnessError.invalidTransition }
        speechOutput = value
    }

    private let taskRecords: (any AssistantTaskRepository)?
    private let communications: (any AgentMessageRepository)?
    private func requireCommunications() throws -> any AgentMessageRepository {
        guard let communications else { throw RecordStorageError.notReady }
        return communications
    }
    private var taskControlInProgress = false
    private let inputAdmission = AgentAdmissionGate(capacity: 32)
    private var delegationInputID: String?
    private var delegationInProgress = false
    private let contextRepository: AgentContextRepository<State>
    private let contextBuilder = AgentChatRequestBuilder<State>()

    private var resultInbox = ActionResultInbox()
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let communicationReceipts = CommunicationReceipts()
    private var containerFailures: [ContainerFailureEvent] = []
    public private(set) var containerFailureEvictions: UInt64 = 0
    public func receivedContainerFailures() -> [ContainerFailureEvent] { containerFailures }
    public func observeFailure(_ event: ContainerFailureEvent) throws {
        try event.validate()
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        if let index = containerFailures.firstIndex(where: { $0.id == event.id && $0.scopeID == event.scopeID }) {
            if event.occurrences >= containerFailures[index].occurrences { containerFailures[index] = event }
        } else {
            if containerFailures.count == 128 {
                containerFailures.removeFirst()
                containerFailureEvictions += 1
            }
            containerFailures.append(event)
        }
    }
    private var executionCancellationBarrier = false
    public func setExecutionCancellationBarrier(_ held: Bool) {
        executionCancellationBarrier = held
        if !held { drain() }
    }
    /// Called after the execution owner has joined cancellation. Unknown native effects stay explicit.
    public func settleInterruptedExecution(sessionID: String) async throws {
        for key in Array(pendingRounds.keys) {
            guard var parked = pendingRounds[key], parked.cancelled, parked.input.sessionID == sessionID else {
                continue
            }
            for index in parked.calls.indices where parked.calls[index].result == nil {
                let result = ToolResult(
                    callID: parked.calls[index].id,
                    value: "Interrupted; execution outcome was not confirmed. Do not assume effects were rolled back.",
                    isError: true, failureCode: "cancelled", completion: .completed, roundID: key)
                if parked.calls[index].tool {
                    try await conversations.recordToolOutcome(
                        result.callID, for: parked.input.id, state: .cancelled,
                        output: result.value, error: result.failureCode)
                    guard let latest = pendingRounds[key] else { break }
                    parked = latest
                }
                if parked.calls[index].result == nil { parked.calls[index].result = result }
            }
            guard pendingRounds[key] != nil else { continue }
            parked.receipt = parked.receipt ?? GenerationRoundResult(roundID: key)
            if !parked.queued {
                try queue.admit(parked.input, disposition: .enqueue(priority: 100))
                parked.queued = true
            }
            pendingRounds[key] = parked
        }
        drain()
    }
    private var coordination: [String: AssistantInputCoordination] = [:]
    private var mergedResults: [String: [ChatMessage]] = [:]
    private var semanticMessages: [String: AssistantInputMessage] = [:]
    private var semanticAttachments: [String: [ChatMessage]] = [:]
    private var semanticSequence: UInt64 = 0
    private let clockDate = Date()
    private let clockUptime = ProcessInfo.processInfo.systemUptime
    private var blockedSessions: Set<String> = []
    private var interruptedIntents: [String: [String]] = [:]
    private var inputDecisionFeedback: (@Sendable (InputDisposition, String) async -> Void)?
    func bindInputDecisionFeedback(_ callback: @escaping @Sendable (InputDisposition, String) async -> Void) {
        inputDecisionFeedback = callback
    }
    private let inputQueueStatus: @Sendable (Int, Int) async -> Void
    private func publishInputQueue() async { await inputQueueStatus(queue.count, decisionPending.count) }
    private let fullDuplex: Bool
    private let inputDecision: AssistantInputDecision?
    private var decisionPending: [InputDecisionSnapshot] = []
    private var decisionWorker: Task<Void, Never>?
    private var inputInterruption: (@Sendable (String) async throws -> Void)?
    private var latestReplySnippet = ""
    public func bindInputInterruption(_ callback: @escaping @Sendable (String) async throws -> Void) {
        inputInterruption = callback
    }
    private func appendDecisionReply(_ text: String) {
        latestReplySnippet = String((latestReplySnippet + text).suffix(160))
    }
    private func classifyPendingInputs() {
        guard decisionWorker == nil, let inputDecision else { return }
        decisionWorker = Task {
            defer { decisionWorker = nil }
            while !decisionPending.isEmpty, !Task.isCancelled, lifecycle != .stopped {
                let queued = decisionPending[0]
                let snapshot = InputDecisionSnapshot(
                    input: queued.input, text: queued.text,
                    occupied: worker != nil || !pendingRounds.isEmpty || !replyInputs.isEmpty,
                    context: queued.context, protectsAnswer: queued.protectsAnswer, receivedAt: queued.receivedAt)
                let observedEpoch = generationEpoch
                let disposition = await inputDecision.classify(snapshot)
                guard !Task.isCancelled, lifecycle != .stopped else { return }
                guard decisionPending.first?.input.id == snapshot.input.id else { continue }
                let input = snapshot.input
                do {
                    if var evidence = coordination[input.id] {
                        evidence.decision = disposition.rawValue
                        evidence.route = await inputDecision.lastRoute
                        coordination[input.id] = evidence
                        try await conversations.recordCoordination(evidence, for: input.id)
                    }
                    guard decisionPending.first?.input.id == input.id, lifecycle != .stopped else { continue }
                    decisionPending.removeFirst()
                    if disposition == .discard {
                        try await contextRepository.update { try $0.transitionWork(input.id, to: .completed) }
                        try await conversations.finish(input.id, state: .completed, reason: "decision.discard")
                        replyInputs.remove(input.id)
                        coordination[input.id] = nil
                        semanticMessages[input.id] = nil
                        semanticAttachments[input.id] = nil
                        inputInteractions[input.id] = nil
                        if lifecycle == .running, !Task.isCancelled {
                            await inputDecisionFeedback?(.discard, input.id)
                        }
                        publishReplyActivity(for: input)
                        await publishInputQueue()
                        continue
                    }
                    try queue.admit(input, disposition: .enqueue(priority: 0))
                    blockedSessions.remove(input.sessionID)
                    replyInputs.insert(input.id)
                    if disposition == .interrupt, observedEpoch == generationEpoch, let inputInterruption {
                        try await inputInterruption(input.sessionID)
                        if lifecycle == .running, !Task.isCancelled {
                            await inputDecisionFeedback?(.interrupt, input.id)
                        }
                    }
                    await publishInputQueue()
                    if lifecycle == .running { drain() }
                } catch {
                    decisionPending.removeAll { $0.input.id == input.id }
                    queue.remove(id: input.id)
                    do {
                        try await contextRepository.update { context in
                            if context.work[input.id]?.state.terminal == false {
                                try context.transitionWork(input.id, to: .failed)
                            }
                        }
                        try await conversations.finish(
                            input.id, state: .failed, error: "Input decision admission failed")
                    } catch { emit(.control("agent.historyError: \(error)"), for: input) }
                    coordination[input.id] = nil
                    semanticMessages[input.id] = nil
                    semanticAttachments[input.id] = nil
                    replyInputs.remove(input.id)
                    emit(.control("agent.error: input decision failed: \(error)"), for: input)
                }
            }
        }
    }
    private var lifecycle: AgentLifecycle = .registered
    private var queue: SignalInbox
    private var admitting = 0
    private var admittingInputs: [String: String] = [:]
    private var cancelledAdmissions: Set<String> = []
    private struct ContinuationRound: Sendable {
        let request: ChatRequest
        let inputText: String
        let ordinal: Int
        let budget: AgentTaskBudget
        let protectedSuffixCount: Int
        let readyAt: Date
        let capability: any ChatCapability
        let requestTaskID: String?
        let boundaryMessages: [ChatMessage]
    }
    private var continuationRounds: [String: ContinuationRound] = [:]
    private var generationEpoch: UInt64 = 0
    private var currentOrdinal = 0
    private var roundCoordinator: AgentRoundCoordinator?

    private var processed = 0
    private let capacity: Int
    private let chatProvider: @Sendable () async throws -> any ChatCapability
    private let communicationPolicy: CommunicationDeclaration
    private var requestSkillIDs: [String] = []
    private var modelCapabilities: CapabilityRegistry
    private let usesSkills: Bool
    private var requestCatalog: CapabilityRegistry?
    private let promptTemplates: PromptTemplates
    private let prompt: @Sendable (CapabilityRegistry) throws -> String
    private var hostCancellationInProgress = false
    private var hostCancellationSession: String?
    private var hostCancellationClosesSession = false
    private var reportHostCancellationFailure = false
    private var hostCancelledInput: (id: String, round: String?)?
    private var worker: Task<Void, Never>?
    private var activeInput: AgentInput?
    private var begunInputID: String?
    private var begunSession: String?
    private var begunTurn: AgentTurn?
    private var begunRoundID: String?
    private var outputSequence: UInt64 = 0
    private let conversations: AssistantHistoryStore
    private let observations:
        @Sendable ([AgentChatObservation], AgentInput, any ChatCapability) async throws -> [ChatMessage]
    private let modelName: @Sendable () async throws -> String
    private var generationFinishReason: String?
    private struct RoundCall {
        let id: String
        let path: String
        let tool: Bool
        let native: ChatToolCall?
        var result: ToolResult?
        var actionResult: ActionResult?
        var rejection: CallRejection?
        var modelGenerated = true
        var forwarded = false
        var completedAt: Date?
    }
    private struct RoundSuspended: Error {}
    private struct PendingRound {
        let input: AgentInput
        let initial: ChatRequest
        let text: String
        let userIntent: String
        let chat: any ChatCapability
        let generationError: (any Error)?
        let ordinal: Int
        let budget: AgentTaskBudget?
        let requestTaskID: String?
        let catalog: CapabilityRegistry?
        let capabilities: CapabilityRegistry
        let skillIDs: [String]
        var coordinator: AgentRoundCoordinator?
        var calls: [RoundCall]
        var receipt: GenerationRoundResult?
        var resultBytes: Int
        let deferred: [(String, String, [String: String], Bool)]
        let finishReason: String?
        let bindings: [String: String]
        let imageScopes: [String: String]
        let imageIDs: Set<String>
        var queued = false
        var cancelled = false
        var publishing = false
    }
    private var pendingRounds: [String: PendingRound] = [:]
    private var batchMembers: [String: [AgentInput]] = [:]
    private var batchTexts: [String: String] = [:]
    private var roundID: String?
    private var roundCalls: [RoundCall] = []
    private var roundReceipt: GenerationRoundResult?
    private var generationCalls = 0
    private var roundContinuationInputText = ""
    private var roundSuffixCount = 1
    private var budget: AgentTaskBudget?
    private var resultBytes = 0
    private var feedbackFailure: String?

    private var pendingInteractions: [String] = []
    private var foregroundInteraction: String?
    private var recognitionInteractions: [String: [AgentTaskView]] = [:]
    private let reportsReplyActivity: Bool
    private var replyActivityParent: AgentInput?
    private var acknowledgedSpeech: (session: String, root: String)?
    private var publishedReplyActivity: (session: String, occupied: Bool, root: String)?
    private var replyInputs: Set<String> = []
    private var replyTasks: Set<String> = []
    private var inputInteractions: [String: [AgentTaskView]] = [:]
    private var immediateInputs: Set<String> = []
    private var routingWorkers: [String: Task<Void, Never>] = [:]
    private var routingSessions: [String: String] = [:]
    private var deferredCommunications: [(String, String, [String: String], Bool)] = []
    private struct WriterNotice {
        let input: AgentInput
        let scopeID: String
        let originDialog: String
        let kind: WriterDelegationEvent.Kind
        let interactionID: String?
        let text: String
    }
    private var writerNotices: [WriterNotice] = []
    private var activeWriterNoticeID: String?

    private static var beginReply: InternalAction {
        InternalAction(
            domain: "UI", module: "Caption", function: "beginReplyTurn", channel: "Display")
    }
    private static var clearReply: InternalAction {
        InternalAction(
            domain: "UI", module: "Caption", function: "clearReply", channel: "Display", optional: ["replyInputID"])
    }
    private var captionInputStarts: [String: (incarnation: String?, turn: AgentTurn)] = [:]
    private var replyWaitingRequest: String?
    private var replyPresentation: (@Sendable (Bool) async -> Void)?
    /// Generic request-latency facts. The role owns content and calls its own presentation tools.
    func bindReplyWaiting(_ callback: @escaping @Sendable (Bool) async -> Void) { replyPresentation = callback }
    private static var replyWaiting: InternalAction {
        InternalAction(
            domain: "UI", module: "Expression", function: "setReplyWaiting", channel: "Display",
            required: ["enabled", "requestID"])
    }
    private static var playback: InternalAction {
        InternalAction(
            domain: "Speech", module: "Playback", function: "speak", channel: "Speech", required: ["audioID"])
    }
    private static var caption: InternalAction {
        InternalAction(
            domain: "UI", module: "Caption", function: "print", channel: "Display", required: ["text"])
    }

    // MARK: - Registration

    private let uiHome: UIHomeContainer?
    private let uiSessionID: String?
    private var uiInputs = AgentUIInputs()
    private var uiTextOrdinal: UInt64 = 0
    private let stateContext: AgentStateContext?
    private var ephemeralImageIDs: Set<String> = []
    private var resourceBindings: [String: String] = [:]
    private var imageScopes: [String: String] = [:]

    public init(
        stateContext: AgentStateContext? = nil,
        speechOutput: (any AgentSpeechOutput)? = nil,
        inputDecision: AssistantInputDecision? = nil, fullDuplex: Bool = false,
        inputQueueStatus: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
        uiHome: UIHomeContainer? = nil, uiSessionID: String? = nil,
        capacity: Int = 32, reportsReplyActivity: Bool = false,
        outputCapacity: Int = 256, chat: (any ChatCapability)? = nil,
        chatProvider: (@Sendable () async throws -> any ChatCapability)? = nil,
        configuration: AgentConfiguration? = nil,
        conversations: AssistantHistoryStore = AssistantHistoryStore(),
        communications: (any AgentMessageRepository)? = nil,
        modelName: @escaping @Sendable () async throws -> String = { "Unspecified model" },
        observations:
            @escaping @Sendable ([AgentChatObservation], AgentInput, any ChatCapability) async throws -> [ChatMessage] =
            { _, _, _ in [] },
        context: AgentContextRepository<State>,
        capabilities: CapabilityRegistry? = nil,
        prompt: (@Sendable (CapabilityRegistry) throws -> String)? = nil
    ) throws {
        self.inputQueueStatus = inputQueueStatus
        self.fullDuplex = fullDuplex
        self.inputDecision = inputDecision
        self.speechOutput = speechOutput
        self.uiHome = uiHome
        self.uiSessionID = uiSessionID
        guard uiHome == nil || uiSessionID != nil else { throw CommunicationError.invalidPayload }
        guard (1...8191).contains(capacity), (1...8192).contains(outputCapacity) else {
            throw CommunicationError.invalidPayload
        }
        let skillStream = AsyncStream<AgentTaskSkillState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        skillUpdates = skillStream.stream
        skillContinuation = skillStream.continuation
        self.stateContext = stateContext
        self.reportsReplyActivity = reportsReplyActivity
        queue = try SignalInbox(capacity: capacity + (fullDuplex ? 33 : 1))
        self.contextRepository = context
        guard contextRepository.agentID == State.agentID else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: State.configurationName)
        guard configuration.agentID == State.agentID else { throw AgentConfigurationError.identityMismatch }
        let runtimeCapabilities = try State.runtimeCapabilities(capabilities ?? configuration.capabilities)
        descriptor = AgentDescriptor(
            category: configuration.category,
            id: configuration.agentID, name: State.configurationName,
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.communication, .actionCall, .toolCall, .control, .scheduling],
            capabilities: runtimeCapabilities)
        self.capacity = capacity
        self.chatProvider =
            chatProvider ?? {
                guard let chat else { throw CapabilityError.unavailable("Chat capability not configured") }
                return chat
            }
        let supportsSkills = State.supportsSkills
        guard !supportsSkills || stateContext != nil else {
            throw AgentConfigurationError.invalidField("State context required")
        }
        usesSkills = supportsSkills
        if supportsSkills, let communications {
            guard conversations.tasks.storageScope == communications.storageScope else {
                throw RecordStorageError.invalidRecord
            }
        }
        taskRecords = supportsSkills ? conversations.tasks : nil
        self.communicationPolicy = configuration.communication
        self.modelCapabilities = try AgentCommunicationAdapter.catalog(
            runtimeCapabilities, policy: configuration.communication)
        self.promptTemplates = try AgentPrompts.load(named: State.configurationName)
        self.prompt = prompt ?? State.systemPrompt
        self.observations = observations
        self.conversations = conversations
        self.communications = communications
        self.modelName = modelName
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
    }
    /// Shared with explicit model diagnostics; capability declarations remain in role JSON.
    public nonisolated static func systemPrompt(capabilities: CapabilityRegistry) throws -> String {
        try State.systemPrompt(capabilities)
    }

    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(
            internalActions: [playback, beginReply, clearReply, caption, replyWaiting]
                .filter { grant in
                    !model.internalActions.contains { $0.path == grant.path }
                })
    }

    /// Shared speech/caption latency policy, independent of shared lexical parsing.
    public nonisolated static var textSegmentation: TextSegmentationPolicy {
        get throws {
            try TextSegmentationPolicy(hanziLimit: 60, otherLimit: 120, firstHanziLimit: 20, firstOtherLimit: 60)
        }
    }

    /// Agent-owned text expansion. Speech text is replaced with an audioID before Gateway admission.
    public nonisolated static func mapText(_ text: String) throws -> [GenerationEvent] {
        [
            .action(
                ActionCall(actionPath: playback.path, channel: playback.channel, parameters: ["text": text])),
            .action(try caption.call(["text": text])),
        ]
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        try await AgentChatHistoryContext.attach(repository: contextRepository, store: conversations)
        _ = try await conversations.readCurrent()
        if usesSkills {
            let fixedCapabilities = descriptor.capabilities
            let base = try AgentConfigurations.baseSkills(named: State.configurationName)
            try await contextRepository.update {
                var skills = $0.state.skillState ?? AgentTaskSkillState()
                try skills.initialize(fixed: fixedCapabilities, baseSkills: base)
                $0.state.skillState = skills
            }
        }
        if let skills = try await contextRepository.snapshot().state.skillState { skillContinuation.yield(skills) }
        lifecycle = .running
        try await startUIInputs()
    }
    private func startUIInputs() async throws {
        guard let uiHome, let uiSessionID else { return }
        let source = await uiHome.requests
        let task = try await consumeUI(source, sessionID: uiSessionID) { agent, value, context in
            switch value {
            case .text(let text): try await agent.handleUIText(text, context: context)
            }
        }
        uiInputs.append(task)
    }
    private func stopUIInputs() async { await uiInputs.retire(for: descriptor.id)() }
    private func handleUIText(_ text: String, context: ProcessingContext) async throws {
        guard !text.isEmpty, text.utf8.count <= 16_384, uiTextOrdinal < UInt64.max else {
            throw CommunicationError.invalidPayload
        }
        uiTextOrdinal += 1
        let processing = ProcessingContext(
            requestID: context.requestID, sessionID: context.sessionID, generation: context.generation,
            source: context.source, rootID: context.rootID, parentID: context.parentID,
            turn: AgentTurn(id: context.requestID, ordinal: uiTextOrdinal))
        try await receive(processing.input(.text(text)))
    }
    public func pause() async throws {
        await stopUIInputs()
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        lifecycle = .paused
        var cancellationFailure: (any Error)?
        if State.acceptsDirectedUserInput {
            do {
                let views = (try await contextRepository.snapshot()).state.taskViews ?? [:]
                for view in views.values
                where !view.terminal && view.stage == .running && view.scope.executor != .writer {
                    let anchor = AgentInput(
                        id: UUID().uuidString, sessionID: view.scope.sessionID,
                        payload: .event("inference.suspended"))
                    let signal = try AgentTaskContent(text: "Inference suspended").signal(.cancel, scope: view.scope)
                    let report = try await communicate(signal.message(), parent: anchor, to: view.scope.executor)
                    guard report.failure == nil, report.rejected.isEmpty, report.delivered.contains(view.scope.executor)
                    else {
                        throw CommunicationError.unavailableTarget
                    }
                }
            } catch { cancellationFailure = error }
        }
        let current = activeInput
        let currentRound = roundID
        decisionWorker?.cancel()
        await decisionWorker?.value
        let parked = pendingRounds
        var seen: Set<String> = []
        let pending =
            (queue.inputs + decisionPending.map(\.input) + parked.values.map(\.input)
            + batchMembers.values.flatMap { $0 }).filter {
                $0.id != current?.id && seen.insert($0.id).inserted
            }
        decisionPending.removeAll()
        pendingRounds.removeAll()
        batchMembers.removeAll()
        batchTexts.removeAll()
        mergedResults.removeAll()
        coordination.removeAll()
        semanticMessages.removeAll()
        semanticAttachments.removeAll()
        blockedSessions.removeAll()
        interruptedIntents.removeAll()
        queue.removeAll()
        worker?.cancel()
        if let current { await speechOutput?.cancel(input: current) }
        await worker?.value
        for input in pending + (current.map { [$0] } ?? []) {
            continuationRounds[input.id] = nil
            inputInteractions[input.id] = nil
            try await contextRepository.update {
                if $0.work[input.id]?.state.terminal == false { try $0.transitionWork(input.id, to: .cancelled) }
            }
            do {
                try await conversations.finish(input.id, state: .cancelled, error: "Inference suspended")
            } catch AssistantHistoryError.missingTurn {}
            replyInputs.remove(input.id)
            let terminalRound =
                input.id == current?.id ? currentRound : parked.first { $0.value.input.id == input.id }?.key
            emit(.control("agent.cancelled"), for: input, terminalRound: terminalRound)
            if let scope = input.taskScope,
                (try await contextRepository.snapshot()).state.taskViews?[scope.id]?.terminal != true
            {
                try await reportFixedTask(
                    scope, input: input,
                    result: ToolResult(callID: input.id, value: "Inference suspended", isError: true),
                    status: .cancelled)
            }
        }
        let fixed = descriptor.capabilities
        try await contextRepository.update {
            try $0.state.skillState?.interruptSession(fixed: fixed)
            $0.state.reconcileTaskCompressions()
        }
        if let skills = try await contextRepository.snapshot().state.skillState { skillContinuation.yield(skills) }
        await publishInputQueue()
        if let replyActivityParent { publishReplyActivity(for: replyActivityParent) }
        if let cancellationFailure { throw cancellationFailure }
    }
    public func resume() async throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        await stopUIInputs()
        lifecycle = .running
        try await startUIInputs()
        drain()
    }
    public func stop() async {
        lifecycle = .stopped
        decisionWorker?.cancel()
        await inputDecision?.stop()
        await decisionWorker?.value
        let classifying = decisionPending.map(\.input)
        decisionPending.removeAll()

        await stopUIInputs()
        lifecycle = .stopped
        writerNotices.removeAll()
        var seen: Set<String> = []
        let queued =
            (queue.inputs + classifying + pendingRounds.values.map(\.input) + batchMembers.values.flatMap { $0 }).filter
        { seen.insert($0.id).inserted && $0.id != activeInput?.id }
        pendingRounds.removeAll()
        batchMembers.removeAll()
        batchTexts.removeAll()
        mergedResults.removeAll()
        coordination.removeAll()
        semanticMessages.removeAll()
        semanticAttachments.removeAll()
        blockedSessions.removeAll()
        queue.removeAll()
        for pending in queued {
            do {
                try await contextRepository.update { context in
                    if context.work[pending.id]?.state.terminal == false {
                        try context.transitionWork(pending.id, to: .interrupted)
                    }
                }
            } catch { emit(.control("agent.historyError: \(error)"), for: pending) }
            do {
                try await conversations.finish(pending.id, state: .interrupted, error: "Agent stopped")
            } catch AssistantHistoryError.missingTurn {} catch {
                emit(.control("agent.historyError: \(error)"), for: pending)
            }
        }
        continuationRounds.removeAll()
        roundCoordinator?.cancel()
        worker?.cancel()
        for task in routingWorkers.values { task.cancel() }
        await communicationReceipts.close()
        for task in routingWorkers.values { await task.value }
        routingWorkers.removeAll()
        await speechOutput?.stop()
        await worker?.value
        replyInputs.removeAll()
        replyTasks.removeAll()
        await publishInputQueue()
        if let replyActivityParent { publishReplyActivity(for: replyActivityParent) }
        do { try await conversations.checkpoint() } catch {
            if let input = replyActivityParent { emit(.control("agent.historyError: \(error)"), for: input) }
        }
        stateContext?.close()
        continuation.finish()
        skillContinuation.finish()
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {
        if input.metadata.origin == .local {
            try input.context.validate()
            if case .text(let text) = input.payload, text.utf8.count > 16_384 {
                throw CommunicationError.invalidPayload
            }
        }
        let ordered: Bool
        if case .text = input.payload {
            ordered = true
        } else if case .transcript(_, final: true)? = input.payload.perception {
            ordered = true
        } else if case .observation(let message) = input.payload,
            message.content(as: WriterDelegationCompletion.self) != nil
                || message.content(as: AgentTaskSignal.self)?.scope.executor == .writer
        {
            ordered = true
        } else {
            ordered = false
        }
        if ordered && State.agentID == .assistant { try await inputAdmission.acquire() }
        defer { if ordered && State.agentID == .assistant { inputAdmission.release() } }
        do { try await receiveSignal(input) } catch {
            if (error as? CommunicationError) == .invalidPayload {
                ContainerInputMetrics.rejected(input, role: "ChatWorker")
            }
            if input.metadata.origin == .local
                || { if case .some(.transcript(_, final: true)) = input.payload.perception { true } else { false } }(),
                (error as? CommunicationError) != .unauthorized,
                (error as? HarnessError) != .notRunning,
                descriptor.inputs.contains(input.payload.kind)
            {
                emit(.control("agent.error: input rejected: \(error)"), for: input)
                if reportsReplyActivity { publishReplyActivity(for: input, acknowledgingSpeech: true) }
            }
            throw error
        }
    }

    private func receiveSignal(
        _ input: AgentInput, semantic: AssistantInputMessage? = nil, attachments: [ChatMessage] = []
    ) async throws {
        if case .observation(let message) = input.payload, message.contract == ContainerFailureEvent.contract {
            throw CommunicationError.unauthorized
        }
        if case .communicationReceipt(let receipt) = input.payload {
            guard input.metadata.origin == .runtime, receipt.owner.agent == descriptor.id,
                receipt.owner.sessionID == input.sessionID
            else { throw CommunicationError.unauthorized }
            try await communicationReceipts.accept(receipt) { [self] in try await prepareSignal(input) }
            return
        }

        if State.isContextObservation(input) {
            guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
            try await contextRepository.update { try $0.state.applyContextObservation(input) }
            return
        }
        if case .observation(let message) = input.payload,
            let completion = message.content(as: WriterDelegationCompletion.self)
        {
            try await receiveWriterCompletion(completion, input: input)
            return
        }
        if case .observation(let message) = input.payload,
            let signal = message.content(as: AgentTaskSignal.self)
        {
            try await receiveTask(signal, input: input)
            return
        }
        if State.acceptsDirectedUserInput, case .observation(let message) = input.payload,
            let intent = message.content(as: AgentTaskInputIntent.self)
        {
            try await forwardDirectedInput(intent, input: input)
            return
        }
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard semantic != nil || input.metadata.origin == .local || descriptor.inputs.contains(input.payload.kind)
        else {
            throw HarnessError.unsupportedInput
        }
        if case .event = input.payload { throw HarnessError.unsupportedInput }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        if try await acceptPendingFeedback(input) { return }
        if case .roundResult(let result) = input.payload {
            try validateFeedback(input)
            guard result.roundID == roundID, roundReceipt == nil else { throw CommunicationError.unauthorized }
            try await persistFeedback(input)
            try validateFeedback(input)
            guard result.roundID == roundID, roundReceipt == nil else { throw CommunicationError.scopeClosed }
            roundReceipt = result
            return
        }
        if case .actionResult(let result) = input.payload {
            guard input.metadata.origin == .runtime, input.metadata.source == "runtime",
                result.owner.agent == descriptor.id, result.owner.sessionID == input.sessionID
            else { throw CommunicationError.unauthorized }
            if let id = result.callID {
                try validateFeedback(input)
                guard result.roundID == roundID,
                    let index = roundCalls.firstIndex(where: { $0.id == id && !$0.tool }),
                    roundCalls[index].path == result.path.description
                else { throw CommunicationError.unauthorized }
                try await persistFeedback(input)
                try validateFeedback(input)
                guard result.roundID == roundID, roundCalls.indices.contains(index), roundCalls[index].id == id else {
                    throw CommunicationError.scopeClosed
                }
                let value = try Self.completionText(result.completion)
                try acceptResult(
                    .init(
                        callID: id, value: value, isError: result.status != .succeeded,
                        failureCode: result.failure?.rawValue, completion: result.completion ?? .completed,
                        roundID: result.roundID),
                    at: index)
                roundCalls[index].actionResult = result
            }
            if result.callID == nil { try await persistFeedback(input) }
            resultInbox.accept(result)
            return
        }
        if case .toolResult(let result) = input.payload,
            let index = roundCalls.firstIndex(where: { $0.id == result.callID && $0.tool })
        {
            try validateFeedback(input)
            guard result.roundID == nil || result.roundID == roundID else { throw CommunicationError.unauthorized }
            try await persistFeedback(input)
            guard let activeInput else { throw CommunicationError.unauthorized }
            do {
                try await conversations.recordToolOutcome(
                    result.callID, for: activeInput.id,
                    state: result.isCancellationOnly ? .cancelled : (result.hasFailure ? .failed : .completed),
                    output: result.value,
                    error: result.isError ? result.failureCode : nil)
            } catch {
                feedbackFailure = "Native outcome persistence failed"
                throw error
            }
            try validateFeedback(input)
            guard roundCalls.indices.contains(index), roundCalls[index].id == result.callID else {
                throw CommunicationError.scopeClosed
            }
            try acceptResult(result, at: index)
            return
        }
        if case .toolResult = input.payload {
            // A native result must match an in-flight model call. Runtime display completions
            // belong to their internal caller and can never become another Assistant input.
            throw CommunicationError.unauthorized
        }
        // Host control bypasses ordinary admission, including when the queue is full or paused.
        if case .observation(let message) = input.payload, let control = try State.sessionControl(message) {
            guard input.metadata.contract == message.contract, input.metadata.version == 1,
                input.metadata.origin == .local, input.metadata.source == "runtime",
                input.metadata.incarnation == nil
            else { throw CommunicationError.unauthorized }
            try input.validate(message)
            switch control {
            case .interrupt, .close:
                let closesSession = control == .close
                if closesSession { writerNotices.removeAll { $0.input.sessionID == input.sessionID } }
                guard !hostCancellationInProgress else { throw HarnessError.invalidTransition }
                hostCancellationInProgress = true
                hostCancellationSession = input.sessionID
                hostCancellationClosesSession = closesSession
                cancelledAdmissions.formUnion(admittingInputs.filter { $0.value == input.sessionID }.map(\.key))
                defer {
                    hostCancellationInProgress = false
                    hostCancellationSession = nil
                    hostCancellationClosesSession = false
                    drain()
                }
                reportHostCancellationFailure = false
                let cancelledActive = activeInput.flatMap { $0.sessionID == input.sessionID ? $0 : nil }
                let cancelledRound = cancelledActive == nil ? nil : roundID
                if let cancelledActive {
                    hostCancelledInput = (cancelledActive.id, cancelledRound)
                    worker?.cancel()
                }
                let oldIDs = Set(
                    pendingRounds.values.filter { $0.input.sessionID == input.sessionID }.map { $0.input.id }
                )
                .union(
                    continuationRounds.keys.filter { id in
                        queue.inputs.contains { $0.id == id && $0.sessionID == input.sessionID }
                    }
                )
                .union(cancelledActive.map { [$0.id] } ?? [])
                if !closesSession {
                    let oldTexts = oldIDs.flatMap { id in
                        (batchMembers[id]?.map(\.id) ?? [id]).compactMap { memberID -> AssistantInputMessage? in
                            guard let entry = semanticMessages[memberID], entry.senderRole == .user else { return nil }
                            return entry
                        }
                    }.sorted { $0.seq < $1.seq }.map(\.content)
                    if interruptedIntents[input.sessionID] == nil, interruptedIntents.count >= 32 {
                        throw CommunicationError.capacityExceeded
                    }
                    interruptedIntents[input.sessionID] = Array(oldTexts.prefix(32))
                }
                for key in pendingRounds.keys where pendingRounds[key]?.input.sessionID == input.sessionID {
                    pendingRounds[key]?.cancelled = true
                }
                if let cancelledActive { await speechOutput?.cancel(input: cancelledActive) }
                for id in oldIDs where continuationRounds[id] != nil {
                    continuationRounds[id] = nil
                    if let retired = queue.inputs.first(where: { $0.id == id }) {
                        queue.remove(id: id)
                        try await contextRepository.update { context in
                            if context.work[id]?.state.terminal == false {
                                try context.transitionWork(id, to: .cancelled)
                            }
                        }
                        try await conversations.finish(id, state: .cancelled, error: "Reply interrupted")
                        try await finishBatch(retired, cancelled: true)
                    }
                }
                let cancelledQueued = (queue.inputs + decisionPending.map(\.input)).filter { candidate in
                    closesSession && candidate.sessionID == input.sessionID && candidate.id != cancelledActive?.id
                        && !pendingRounds.values.contains(where: { $0.input.id == candidate.id })
                }
                if closesSession { decisionPending.removeAll { $0.input.sessionID == input.sessionID } }
                try await prepareSignal(input)
                for pending in cancelledQueued {
                    replyInputs.remove(pending.id)
                    continuationRounds[pending.id] = nil
                    if pending.id != activeInput?.id {
                        try await contextRepository.update { context in
                            if context.work[pending.id]?.state.terminal == false {
                                try context.transitionWork(pending.id, to: .cancelled)
                            }
                        }
                        do {
                            try await conversations.finish(pending.id, state: .cancelled)
                        } catch AssistantHistoryError.missingTurn {} catch { throw error }
                    }
                }
                for pending in cancelledQueued {
                    queue.remove(id: pending.id)
                    try await finishBatch(pending, cancelled: true)
                }
                if closesSession { blockedSessions.remove(input.sessionID) }
                if activeInput?.sessionID == input.sessionID {
                    let task = worker
                    task?.cancel()
                    await task?.value
                }
                let routing = routingWorkers.filter { routingSessions[$0.key] == input.sessionID }
                for task in routing.values { task.cancel() }
                for task in routing.values { await task.value }
                let views = (try await contextRepository.snapshot()).state.taskViews ?? [:]
                for view in views.values
                where !view.terminal && view.scope.sessionID == input.sessionID
                    && view.scope.requester == descriptor.id && view.scope.execution != .background
                {
                    let signal = try AgentTaskContent(text: "Listening closed").signal(.cancel, scope: view.scope)
                    let report = try await communicate(signal.message(), parent: input, to: view.scope.executor)
                    guard report.failure == nil, report.rejected.isEmpty, report.delivered.contains(view.scope.executor)
                    else { throw CommunicationError.unavailableTarget }
                }
                let fixed = descriptor.capabilities
                try await contextRepository.update { context in
                    let inputs = Set(
                        context.work.filter {
                            $0.value.sessionID == input.sessionID && (closesSession || oldIDs.contains($0.key))
                        }.map(\.key))
                    if closesSession {
                        try context.state.skillState?.cancelSession(input.sessionID, inputs: inputs, fixed: fixed)
                    } else {
                        try context.state.skillState?.interruptSession(input.sessionID, inputs: inputs, fixed: fixed)
                    }
                    context.state.reconcileTaskCompressions()
                }
                if let skills = try await contextRepository.snapshot().state.skillState {
                    skillContinuation.yield(skills)
                }
                if let cancelledActive { finishHostCancellation(cancelledActive, force: true) }
                for pending in cancelledQueued {
                    guard emit(.control("agent.cancelled"), for: pending) else { throw HarnessError.queueFull }
                }
                try await conversations.checkpoint()
                if closesSession {
                    await stateContext?.resetMedia(session: input.sessionID)
                    stateContext?.close(session: input.sessionID)
                    captionInputStarts.removeValue(forKey: input.sessionID)
                }
                publishReplyActivity(for: input)
                if reportHostCancellationFailure { throw HarnessError.queueFull }
            }
            return
        }
        if case .observation(let observation) = input.payload {
            guard let content = observation.perception else { throw HarnessError.unsupportedInput }
            switch content {
            case .transcript(_, final: true), .speechPhase: break
            default: throw HarnessError.unsupportedInput
            }
            _ = try observation.validatedSize()
        }
        if case .speechPhase(.speaking)? = input.payload.perception, let turn = input.turn,
            let previous = captionInputStarts[input.sessionID], previous.incarnation == input.metadata.incarnation,
            turn.ordinal <= previous.turn.ordinal
        {
            return
        }
        if case .some(.speechPhase(.speaking)) = input.payload.perception, let turn = input.turn {
            let views = try await interactionViews(sessionID: input.sessionID)
            if !views.isEmpty {
                guard recognitionInteractions.count < 32 || recognitionInteractions[turn.id] != nil else {
                    throw CommunicationError.capacityExceeded
                }
                recognitionInteractions[turn.id] = views
            }
        }
        if case .some(.speechPhase(let phase)) = input.payload.perception {
            if phase == .empty, let turn = input.turn { recognitionInteractions[turn.id] = nil }
            try await prepareSignal(input)
            try clearCaptionForInputStart(input)
            return
        }
        let isUser = semantic == nil && AssistantInputMessage.isUser(input)
        if isUser {
            let views: [AgentTaskView]
            if let turn = input.turn, input.payload.kind != .text {
                views = recognitionInteractions.removeValue(forKey: turn.id) ?? []
            } else {
                views = try await interactionViews(sessionID: input.sessionID)
            }
            if !views.isEmpty {
                guard inputInteractions[input.id] != nil || inputInteractions.count < capacity + 1 else {
                    throw CommunicationError.capacityExceeded
                }
                inputInteractions[input.id] = views
            }
        }
        guard hostCancellationSession != input.sessionID else { throw HarnessError.invalidTransition }
        let ordinary = queue.inputs.filter { pending in
            !fullDuplex
                || (continuationRounds[pending.id] == nil
                    && !pendingRounds.values.contains { $0.input.id == pending.id })
        }
        let waitingMembers = ordinary.flatMap { batchMembers[$0.id] ?? [$0] }
        guard waitingMembers.count + decisionPending.count + admitting < capacity else { throw HarnessError.queueFull }
        if fullDuplex {
            let live = try await contextRepository.snapshot().work.values.filter { !$0.state.terminal }
            guard live.count + admitting < 64 else { throw HarnessError.queueFull }
            let queued = waitingMembers + decisionPending.map(\.input)
            guard
                queued.reduce(
                    0,
                    { total, queued in
                        total + (Self.inputText(queued)?.utf8.count ?? 0)
                            + (semanticAttachments[queued.id] ?? []).reduce(0) { $0 + $1.content.utf8.count }
                    }) + (Self.inputText(input)?.utf8.count ?? 0)
                    + attachments.reduce(0, { $0 + $1.content.utf8.count }) <= 524_288,
                Set(queued.map { $0.metadata.source } + [input.metadata.source]).count <= 32,
                semantic?.senderRole != .agent
                    || queued.filter({ semanticMessages[$0.id]?.senderRole == .agent }).count < 16
            else { throw CommunicationError.capacityExceeded }
        }
        if let text = Self.inputText(input), text.utf8.count > 16_384 {
            throw CapabilityError.invalidRequest("Agent input exceeds 16 KiB")
        }
        if fullDuplex {
            let attachmentBytes = (Array(semanticAttachments.values) + [attachments]).flatMap { $0 }.reduce(0) {
                $0 + $1.content.utf8.count + ($1.images ?? []).reduce(0) { $0 + $1.data.count }
            }
            guard attachmentBytes <= 32 * 1024 * 1024 else { throw CommunicationError.capacityExceeded }
            guard semanticMessages[input.id] == nil else { throw CommunicationError.outOfOrder }
            guard semantic != nil || isUser else { throw CommunicationError.unauthorized }
            semanticMessages[input.id] =
                try semantic
                ?? makeSemanticMessage(
                    input: input, role: .user,
                    channel: input.payload.kind == .text ? "input" : "speechPerception",
                    content: Self.inputText(input) ?? "")
            semanticAttachments[input.id] = attachments
        }
        var admitted = false
        defer {
            if !admitted {
                semanticMessages[input.id] = nil
                semanticAttachments[input.id] = nil
            }
        }
        admitting += 1
        admittingInputs[input.id] = input.sessionID
        defer {
            admitting -= 1
            admittingInputs[input.id] = nil
            cancelledAdmissions.remove(input.id)
        }
        do { try await prepareSignal(input) } catch {
            inputInteractions[input.id] = nil
            throw error
        }
        let userText: String?
        if case .text(let text) = input.payload {
            userText = text
        } else if case .transcript(let text, final: true)? = input.payload.perception {
            userText = text
        } else {
            userText = nil
        }
        if let userText {
            guard userText.utf8.count <= 16_384 else { throw CommunicationError.invalidPayload }
            do {
                _ = try await conversations.admitUserInput(id: input.id, user: userText, model: "尚未开始")
                if fullDuplex {
                    let evidence = AssistantInputCoordination(
                        source: input.metadata.source, capturedAt: String(input.metadata.capturedAt))
                    coordination[input.id] = evidence
                    try await conversations.recordCoordination(evidence, for: input.id)
                }
            } catch {
                let admissionFailure = error
                do { try await contextRepository.update { try $0.transitionWork(input.id, to: .failed) } } catch {
                    emit(.control("agent.error: admission cleanup failed: \(error)"), for: input)
                }
                do {
                    try await conversations.finish(
                        input.id, state: .failed, error: String(describing: admissionFailure))
                } catch AssistantHistoryError.missingTurn {} catch {
                    emit(.control("agent.historyError: \(error)"), for: input)
                }
                throw admissionFailure
            }
        }
        guard lifecycle == .running || lifecycle == .paused else {
            inputInteractions[input.id] = nil
            throw HarnessError.notRunning
        }
        guard !cancelledAdmissions.contains(input.id), hostCancellationSession != input.sessionID else {
            inputInteractions[input.id] = nil
            try await contextRepository.update { context in
                if context.work[input.id]?.state.terminal == false {
                    try context.transitionWork(input.id, to: .cancelled)
                }
            }
            throw CancellationError()
        }
        if let userText, isUser, inputDecision != nil {
            let interactions = inputInteractions[input.id] ?? []
            let context = ([latestReplySnippet] + interactions.prefix(1).map(\.text)).joined(separator: "\n")
            decisionPending.append(
                .init(
                    input: input, text: userText,
                    occupied: worker != nil || !pendingRounds.isEmpty || !replyInputs.isEmpty, context: context,
                    protectsAnswer: !interactions.isEmpty))
            if reportsReplyActivity { publishReplyActivity(for: input, acknowledgingSpeech: true) }
            await publishInputQueue()
            admitted = true
            classifyPendingInputs()
            return
        }
        try queue.admit(input, disposition: .enqueue(priority: 0))
        admitted = true
        if isUser { blockedSessions.remove(input.sessionID) }
        if fullDuplex { await publishInputQueue() }
        if reportsReplyActivity {
            replyInputs.insert(input.id)
            publishReplyActivity(for: input, acknowledgingSpeech: true)
        }
        if lifecycle == .running { drain() }
    }

    private func interactionViews(sessionID: String) async throws -> [AgentTaskView] {
        let foreground = foregroundInteraction
        let views = try await contextRepository.snapshot().state.taskViews ?? [:]
        return views.values.filter {
            !$0.terminal && $0.scope.sessionID == sessionID && $0.stage == .waitingUser
                && ($0.scope.id == foreground || $0.scope.executor == .writer)
        }
    }

    // MARK: - Decision workers

    private func handleText(_ incomingText: String, input: AgentInput) -> Bool {
        let text = batchTexts[input.id] ?? incomingText
        activeInput = input
        if immediateInputs.remove(input.id) != nil {
            worker = Task { await self.emitImmediate(text, for: input) }
            return true
        }
        worker = Task {
            do {
                if usesSkills && continuationRounds[input.id] == nil
                    && !pendingRounds.values.contains(where: { $0.input.id == input.id })
                {
                    let countsIdle: Bool
                    switch input.payload {
                    case .text: countsIdle = AssistantInputMessage.isUser(input) && input.taskScope == nil
                    case .observation(let observation):
                        if case .transcript(_, final: true)? = observation.perception {
                            countsIdle = true
                        } else {
                            countsIdle = false
                        }
                    default: countsIdle = false
                    }
                    try await contextRepository.update {
                        try $0.state.skillState?.beginDecision(
                            input.id, sessionID: input.sessionID, countsIdle: countsIdle)
                    }
                }
                let binding: any ChatCapability
                if let resumed = continuationRounds[input.id] {
                    binding = resumed.capability
                } else {
                    binding = try await chatProvider()
                }
                await self.generate(text, input: input, using: binding)
            } catch {
                do {
                    if try await retainPreparedBatch(input, error: error) {
                        activeInput = nil
                        worker = nil
                        drain()
                        return
                    }
                } catch { emit(.control("agent.error: batch retention failed: \(error)"), for: input) }
                emitFailure(error, for: input)
                do { try await contextRepository.update { try $0.transitionWork(input.id, to: .failed) } } catch {
                    emit(.control("agent.error: context commit failed: \(error)"), for: input)
                }
                do {
                    try await finishLocalDecision(input: input, failed: true, failure: String(describing: error))
                } catch { emit(.control("agent.error: task cleanup failed: \(error)"), for: input) }
                do { try await conversations.finish(input.id, state: .failed, error: String(describing: error)) } catch
                { emit(.control("agent.historyError: \(error)"), for: input) }
                if let scope = input.taskScope {
                    do {
                        try await reportFixedTask(
                            scope, input: input,
                            result: ToolResult(
                                callID: input.id,
                                value: String(describing: error), isError: true))
                    } catch { emit(.control("agent.error: task report failed: \(error)"), for: input) }
                }
                do { try await finishBatch(input, failure: String(describing: error)) } catch {
                    emit(.control("agent.historyError: batch cleanup failed: \(error)"), for: input)
                }
                inputInteractions[input.id] = nil
                activeInput = nil
                worker = nil
                finishHostCancellation(input)
                drain()
            }
        }
        return true
    }
    private func makeSemanticMessage(
        input: AgentInput, role: AssistantInputMessage.Role, channel: String, content: String,
        time: Date? = nil
    ) throws -> AssistantInputMessage {
        guard semanticSequence < UInt64.max else { throw CommunicationError.capacityExceeded }
        semanticSequence += 1
        let received = Date()
        let captured = input.metadata.capturedAt
        let eventTime: Date
        if role == .user, captured.isFinite, captured >= 0, captured <= ProcessInfo.processInfo.systemUptime {
            eventTime = clockDate.addingTimeInterval(captured - clockUptime)
        } else {
            eventTime = received
        }
        return AssistantInputMessage(
            seq: semanticSequence, time: time ?? eventTime, senderRole: role, channel: channel, content: content)
    }

    /// A prepared batch remains bounded in memory. Only a new admitted user input retries it.
    private func retainPreparedBatch(_ input: AgentInput, error: any Error) async throws -> Bool {
        guard fullDuplex, !Task.isCancelled, !(error is CancellationError),
            lifecycle == .running || lifecycle == .paused,
            !pendingRounds.values.contains(where: { $0.input.id == input.id }),
            semanticMessages[input.id] != nil
        else { return false }
        let history = try await conversations.readCurrent()
        let requests = history.current.turns.first(where: { $0.id == input.id })?.modelRequests ?? []
        guard !requests.contains(where: { $0.awaitingDispatch != true }) else { return false }
        // Close only the in-memory prepared invocation, so another preparation can replace it.
        if requests.last?.state == .generating {
            try await conversations.finishModelRequest(
                input.id, reason: "preparationFailed", error: String(describing: error))
        }
        try await contextRepository.update { try $0.transitionWork(input.id, to: .queued) }
        if !queue.inputs.contains(where: { $0.id == input.id }) {
            try queue.admit(input, disposition: .enqueue(priority: 0))
        }
        blockedSessions.insert(input.sessionID)
        await publishInputQueue()
        emitFailure(error, for: input)
        return true
    }

    private static func inputText(_ input: AgentInput) -> String? {
        switch input.payload {
        case .text(let text): return text
        case .observation(let message):
            if case .transcript(let text, final: true)? = message.perception { return text }
            return nil
        default: return nil
        }
    }
    private func drain() {
        guard worker == nil, !hostCancellationInProgress, !executionCancellationBarrier,
            pendingRounds.count < 32
                || queue.inputs.contains(where: { input in
                    pendingRounds.values.contains { $0.input.id == input.id && $0.queued }
                })
        else { return }
        while lifecycle == .running && !queue.isEmpty {
            let excludedBlocked = Set(
                queue.inputs.filter { queued in
                    blockedSessions.contains(queued.sessionID)
                        && !pendingRounds.values.contains(where: { $0.input.id == queued.id && $0.queued })
                }.map(\.id))
            guard let entry = queue.take(excluding: excludedBlocked) else { return }
            let input = entry.input
            processed += 1
            if fullDuplex, !pendingRounds.values.contains(where: { $0.input.id == input.id }),
                Self.inputText(input) != nil
            {
                let excluded = Set(pendingRounds.values.map { $0.input.id })
                    .union(queue.inputs.filter { Self.inputText($0) == nil }.map(\.id))
                let entries = [input] + queue.takeAll(sessionID: input.sessionID, excluding: excluded).map(\.input)
                var seen: Set<String> = []
                let members = entries.flatMap { batchMembers[$0.id] ?? [$0] }.filter { seen.insert($0.id).inserted }
                let results = members.flatMap { semanticAttachments[$0.id] ?? [] }
                for entry in entries where entry.id != input.id {
                    batchMembers[entry.id] = nil
                    batchTexts[entry.id] = nil
                    mergedResults[entry.id] = nil
                }
                mergedResults[input.id] = results
                batchMembers[input.id] = members
                do {
                    let values: [AssistantInputMessage] = try members.map { member in
                        guard let value = semanticMessages[member.id] else { throw CommunicationError.invalidPayload }
                        return value
                    }
                    let text = AssistantInputBatch(
                        messages: values, interruptedIntentions: interruptedIntents[input.sessionID]
                    ).text()
                    batchTexts[input.id] = text
                    if handleText(text, input: input) { return }
                } catch {
                    blockedSessions.insert(input.sessionID)
                    do { try queue.admit(input, disposition: .enqueue(priority: 0)) } catch {
                        emitFailure(error, for: input)
                    }
                    emitFailure(error, for: input)
                    return
                }
            }
            switch input.payload {
            case .text(let text):
                if handleText(text, input: input) { return }
            case .observation(let message):
                switch message.perception {
                case .some(.transcript(let text, final: true)):
                    if handleText(text, input: input) { return }
                case .some(.speechPhase(.speaking)):
                    break
                default: break
                }
            // Unsupported input is rejected by the descriptor; receipts are handled before this switch.
            case .communicationReceipt, .image, .audio, .actionResult, .roundResult, .activityEvent, .event: break
            case .toolResult(let result):
                activeInput = input
                worker = Task { await self.emitImmediate(result.value, for: input) }
                return
            }
        }
        if lifecycle == .running, !writerNotices.isEmpty {
            let notice = writerNotices.removeFirst()
            activeWriterNoticeID = notice.input.id
            activeInput = notice.input
            worker = Task { await playWriterNotice(notice) }
        }
    }
    /// A control update, independent of the active model round and formal input FIFO.
    private func clearCaptionForInputStart(_ input: AgentInput) throws {
        guard !fullDuplex, State.agentID == .assistant, case .speechPhase(.speaking)? = input.payload.perception,
            let turn = input.turn
        else { return }
        if let previous = captionInputStarts[input.sessionID], previous.incarnation == input.metadata.incarnation,
            turn.ordinal <= previous.turn.ordinal
        {
            return
        }
        guard captionInputStarts[input.sessionID] != nil || captionInputStarts.count < 32 else {
            throw CommunicationError.capacityExceeded
        }
        let parameters = begunSession == input.sessionID ? begunInputID.map { ["replyInputID": $0] } ?? [:] : [:]
        Logger(subsystem: "dev.mobileharness", category: "SpeechListening").notice("assistant.caption.confirmedOnset")
        let call = try Self.clearReply.call(parameters)
        guard emit(.actionCall(call), for: input), emit(.control("agent.finished"), for: input) else {
            throw HarnessError.queueFull
        }
        captionInputStarts[input.sessionID] = (input.metadata.incarnation, turn)
    }
    private func beginReplyTurn(_ input: AgentInput) throws {
        guard input.turn != nil else { return }
        if begunTurn == input.turn, begunSession == input.sessionID, begunRoundID == roundID, begunInputID == input.id {
            return
        }
        let call = try Self.beginReply.call([:])
        if roundID != nil {
            guard generationCalls < 120 else { throw GenerationError.limitExceeded }
            generationCalls += 1
        }
        guard try emitAction(call, for: input) else { throw HarnessError.queueFull }
        begunInputID = input.id
        begunSession = input.sessionID
        begunTurn = input.turn
        begunRoundID = roundID
    }
    private func generate(_ text: String, input: AgentInput, using chat: any ChatCapability) async {
        await publishInputQueue()
        defer {
            if continuationRounds[input.id] == nil && !pendingRounds.values.contains(where: { $0.input.id == input.id })
            {
                inputInteractions[input.id] = nil
            }
            activeInput = nil
            retireRound()
            roundID = nil
            feedbackFailure = nil
            generationCalls = 0
            budget = nil
            resultBytes = 0
            worker = nil
            finishHostCancellation(input)
            drain()
        }
        let resumed = continuationRounds.removeValue(forKey: input.id)
        var recorded = resumed != nil
        currentOrdinal = resumed?.ordinal ?? 0
        generationCalls = 0
        budget = resumed?.budget
        resultBytes = 0
        generationFinishReason = nil
        do {
            if let key = pendingRounds.first(where: { $0.value.input.id == input.id && $0.value.queued })?.key,
                let parked = pendingRounds.removeValue(forKey: key)
            {
                recorded = true
                roundID = key
                currentOrdinal = parked.ordinal
                budget = parked.budget
                requestCatalog = parked.catalog
                modelCapabilities = parked.capabilities
                requestSkillIDs = parked.skillIDs
                roundCoordinator = parked.coordinator
                roundCalls = parked.calls
                roundReceipt = parked.receipt
                resultBytes = parked.resultBytes
                deferredCommunications = parked.deferred
                generationFinishReason = parked.finishReason
                resourceBindings = parked.bindings
                imageScopes = parked.imageScopes
                ephemeralImageIDs = parked.imageIDs
                let next = try await completeRound(
                    parked.initial, input: input, using: parked.chat,
                    text: parked.text, userIntent: parked.userIntent,
                    generationError: parked.cancelled ? CancellationError() : parked.generationError)
                try await settleRound(next, input: input, chat: parked.chat, requestTaskID: parked.requestTaskID)
                return
            }
            let selection = AgentDecisionContext(
                snapshot: try await contextRepository.snapshot(), input: input,
                memberIDs: batchMembers[input.id]?.map(\.id))
            recorded = recorded || selection.snapshot.state.history.current.turns.contains(where: { $0.id == input.id })
            let members = batchMembers[input.id] ?? [input]
            let memberIDs = members.map(\.id)
            let memberEvidence = members.compactMap { member in
                coordination[member.id].map { AssistantInputCoordination.Member(id: member.id, evidence: $0) }
            }
            for member in members {
                if var evidence = coordination[member.id] {
                    evidence.batchID = input.id
                    evidence.memberIDs = memberIDs
                    if member.id == input.id { evidence.members = memberEvidence }
                    coordination[member.id] = evidence
                    try await conversations.recordCoordination(evidence, for: member.id)
                }
            }
            let decision = try contextBuilder.build(state: selection, batch: selection.batch())
            try await contextRepository.update { context in
                try context.consume(decision.batch, retainingLast: 4096)
                try context.transitionWork(input.id, to: .running)
            }
            if let skills = decision.state.skillState {
                guard
                    skills.activeTaskID == nil || skills.taskID(for: input.id) == skills.activeTaskID
                else {
                    throw CommunicationError.scopeClosed
                }
                modelCapabilities = try AgentCommunicationAdapter.catalog(
                    skills.registry(fixed: descriptor.capabilities), policy: communicationPolicy)
            }
            let dynamicSystem = try State.systemPrompt(
                modelCapabilities, skills: decision.state.skillState, communication: communicationPolicy)
            let dynamicTools: [ChatToolDefinition] =
                await chat.supportsToolCalls
                ? try modelCapabilities.tools.compactMap { registration in
                    guard let definition = registration.definition else { return nil }
                    return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
                } : []
            let request: ChatRequest
            if let resumed {
                let history = try await conversations.readCurrent()
                let closedTaskContext =
                    decision.state.skillState != nil
                    && resumed.requestTaskID != nil
                    && resumed.requestTaskID != decision.state.skillState?.activeTaskID
                var messages =
                    closedTaskContext
                    ? try decision.messages(system: dynamicSystem, user: text) + resumed.boundaryMessages
                    : resumed.request.messages
                if decision.state.skillState != nil {
                    messages.removeAll { $0.role == .system }
                    messages.insert(.init(role: .system, content: dynamicSystem), at: 0)
                }
                let allowed = Set(
                    selection.snapshot.records.filter { $0.taskID == input.taskScope?.id }.compactMap {
                        try? JSONDecoder().decode(SignalEvidence.self, from: $0.data).signalID
                    })
                let intervening =
                    closedTaskContext
                    ? []
                    : history.current.turns.filter { turn in
                        turn.id != input.id && (input.taskScope == nil || allowed.contains(turn.id))
                    }.flatMap { turn in
                        (turn.modelRequests ?? []).filter {
                            $0.state == .completed && $0.date > resumed.readyAt
                                && (decision.state.skillState == nil
                                    || $0.historyTaskID == decision.state.skillState?.activeTaskID)
                        }
                    }.sorted { $0.date < $1.date }
                for invocation in intervening {
                    messages += try AgentChatContextBuilder.messages(for: invocation, templates: promptTemplates)
                }
                messages += mergedResults[input.id] ?? []
                let addsBatch = fullDuplex && (batchMembers[input.id]?.count ?? 0) > 1 && messages.last?.content != text
                if addsBatch { messages.append(.init(role: .user, content: text)) }
                let protectedCount =
                    resumed.protectedSuffixCount + (mergedResults[input.id]?.count ?? 0) + (addsBatch ? 1 : 0)
                request = try ChatRequest(
                    messages: try AgentChatContextBuilder.retainingRecent(
                        messages, preservingUser: text, protectedSuffixCount: protectedCount),
                    context: resumed.request.context,
                    maximumOutputTokens: resumed.request.maximumOutputTokens,
                    temperature: resumed.request.temperature,
                    tools: decision.state.skillState == nil ? resumed.request.tools : dynamicTools)
            } else {
                var messages = try decision.messages(system: dynamicSystem, user: text)
                if let attachments = mergedResults[input.id], !attachments.isEmpty {
                    let suppliedCalls = Set(attachments.flatMap(\.toolCalls).map(\.id))
                    // A freshly completed group may already be projected in history. Carry it once.
                    messages.removeAll { message in
                        !Set(message.toolCalls.map(\.id)).isDisjoint(with: suppliedCalls)
                            || message.toolCallID.map(suppliedCalls.contains) == true
                    }
                    messages.insert(contentsOf: attachments, at: max(0, messages.count - 1))
                }
                let record = try await beginHistoryRequest(input: input, text: text, messages: messages)
                recorded = true
                try Task.checkCancellation()
                let tools: [ChatToolDefinition]
                if await chat.supportsToolCalls {
                    tools = try modelCapabilities.tools.compactMap { registration in
                        guard let definition = registration.definition else { return nil }
                        return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
                    }
                } else {
                    tools = []
                }
                try await conversations.recordToolDefinitions(
                    tools.map { String(decoding: $0.declaration, as: UTF8.self) }, for: input.id)
                request = try ChatRequest(
                    messages: try AgentChatContextBuilder.retainingRecent(
                        messages, preservingUser: text, protectedSuffixCount: 1 + (mergedResults[input.id]?.count ?? 0)),
                    context: InferenceContext(requestID: input.id, scopeID: input.sessionID),
                    temperature: record.temperature, tools: tools)
            }
            var inputParts = [resumed?.inputText ?? text]
            inputParts += (mergedResults[input.id] ?? []).filter { $0.role != .assistant }.map(\.content)
            if (batchMembers[input.id]?.count ?? 0) > 1, !inputParts.contains(text) { inputParts.append(text) }
            let recordedInput = fullDuplex ? inputParts.joined(separator: "\n") : resumed?.inputText
            let attachmentCount = mergedResults[input.id]?.count ?? 0
            generationEpoch &+= 1
            if budget == nil { budget = try AgentTaskBudget() }
            let next = try await executeRound(
                request, input: input, using: chat, inputText: recordedInput,
                userIntent: text, protectedSuffixCount: resumed?.protectedSuffixCount ?? (1 + attachmentCount))
            try Task.checkCancellation()
            try await settleRound(
                next, input: input, chat: chat, requestTaskID: selection.snapshot.state.skillState?.activeTaskID)
        } catch is RoundSuspended {
            return
        } catch {
            await speechOutput?.cancel(input: input)
            do {
                if try await retainPreparedBatch(input, error: error) { return }
            } catch { emit(.control("agent.error: batch retention failed: \(error)"), for: input) }
            continuationRounds[input.id] = nil
            queue.remove(id: input.id)
            let cancelled = Task.isCancelled || error is CancellationError
            var failure = Self.failureDescription(error)
            do {
                try await contextRepository.update {
                    try $0.transitionWork(
                        input.id,
                        to: Task.isCancelled || error is CancellationError ? .cancelled : .failed)
                }
            } catch { failure += "; context terminal persistence failed: \(error)" }
            if let scope = input.taskScope, !Task.isCancelled {
                do {
                    try await reportFixedTask(
                        scope, input: input,
                        result: ToolResult(callID: input.id, value: String(failure.prefix(1024)), isError: true))
                } catch { failure += "; task report failed: \(error)" }
            }
            do {
                try await finishLocalDecision(
                    input: input, failed: !cancelled, failure: cancelled ? nil : failure, cancelled: cancelled)
            } catch {
                failure += "; local task cleanup failed: \(error)"
            }
            if recorded {
                do {
                    try await conversations.finish(
                        input.id, state: Task.isCancelled || error is CancellationError ? .cancelled : .failed,
                        reason: generationFinishReason, error: failure)
                } catch { failure += "; history persistence failed: \(error)" }
            }
            do { try await finishBatch(input, cancelled: cancelled, failure: failure) } catch {
                failure += "; batch terminal persistence failed: \(error)"
            }
            guard !Task.isCancelled, lifecycle == .running || lifecycle == .paused else { return }
            if cancelled {
                emit(.control("agent.cancelled"), for: input)
            } else {
                emitFailure(error, for: input, detail: failure)
            }
        }
    }

    private func finishBatch(_ input: AgentInput, cancelled: Bool = false, failure: String? = nil) async throws {
        let members = batchMembers.removeValue(forKey: input.id) ?? [input]
        batchTexts[input.id] = nil
        mergedResults[input.id] = nil
        for member in members {
            coordination[member.id] = nil
            semanticMessages[member.id] = nil
            semanticAttachments[member.id] = nil
            if member.id == input.id { continue }
            replyInputs.remove(member.id)
            try await contextRepository.update { context in
                if context.work[member.id]?.state.terminal == false {
                    try context.transitionWork(
                        member.id, to: cancelled ? .cancelled : (failure == nil ? .completed : .failed))
                }
            }
            try await conversations.finish(
                member.id, state: cancelled ? .cancelled : (failure == nil ? .completed : .failed),
                reason: "batch:" + input.id, error: failure)
        }
    }

    private func settleRound(_ next: ChatRequest?, input: AgentInput, chat: any ChatCapability, requestTaskID: String?)
        async throws
    {
        if let next {
            guard let budget else { throw HarnessError.invalidTransition }
            let boundaryMessages = try roundActionResultMessages()
            let previousTaskID = requestTaskID
            let currentTaskID = try await contextRepository.snapshot().state.skillState?.activeTaskID
            let closedTaskContext =
                previousTaskID != nil && previousTaskID != currentTaskID
            continuationRounds[input.id] = ContinuationRound(
                request: next,
                inputText: closedTaskContext
                    ? boundaryMessages.map(\.content).joined(separator: "\n")
                    : roundContinuationInputText, ordinal: currentOrdinal + 1,
                budget: budget, protectedSuffixCount: roundSuffixCount,
                readyAt: Date(), capability: chat,
                requestTaskID: requestTaskID,
                boundaryMessages: boundaryMessages)
            try await contextRepository.update { try $0.transitionWork(input.id, to: .continuation) }
            guard !cancelledAdmissions.contains(input.id), hostCancellationSession != input.sessionID else {
                inputInteractions[input.id] = nil
                throw CancellationError()
            }
            try queue.admit(input, disposition: .enqueue(priority: 0))
            return
        }
        try await contextRepository.update { try $0.transitionWork(input.id, to: .completed) }
        guard lifecycle == .running || lifecycle == .paused else { return }
        try await finishLocalDecision(input: input, failed: false)
        try await completeTaskDecision(input)
        try await conversations.finish(input.id, state: .completed, reason: generationFinishReason)
        try await finishBatch(input)
        emit(.control("agent.finished"), for: input)
    }

    private func executeRound(
        _ initial: ChatRequest, input: AgentInput, using chat: any ChatCapability,
        inputText suppliedText: String?, userIntent: String, protectedSuffixCount: Int
    )
        async throws -> ChatRequest?
    {
        var request = initial
        let inputText = suppliedText ?? initial.messages.last?.content ?? ""
        do {
            generationCalls = 0
            resultBytes = 0
            try budget?.reserveRequest()
            if let budget { try await contextRepository.update { try $0.recordBudget(budget, for: input.id) } }
            retireRound()
            let decisionID = UUID().uuidString
            roundID = decisionID
            roundReceipt = nil
            roundCoordinator = AgentRoundCoordinator(id: decisionID, taskID: input.id)
            guard let requestID = roundID else { throw CommunicationError.invalidPayload }
            generationFinishReason = nil
            let decisionContext = try await contextRepository.snapshot()
            requestSkillIDs = decisionContext.state.skillState?.loaded ?? []
            let catalog =
                usesSkills
                ? try AgentCommunicationAdapter.catalog(
                    AgentSkillLoader.registry(requestSkillIDs, fixed: descriptor.capabilities),
                    policy: communicationPolicy)
                : modelCapabilities
            requestCatalog = catalog
            var stateMessages = request.messages
            var stateMessageCount = 0
            var requestedStates: [String]?
            ephemeralImageIDs.removeAll()
            resourceBindings.removeAll()
            imageScopes.removeAll()
            if usesSkills {
                guard let stateContext else { throw CommunicationError.invalidPayload }
                let names = try AgentSkillLoader.useStates(requestSkillIDs)
                await stateContext.synchronize(
                    session: input.sessionID, dialog: decisionContext.state.history.current.id)
                let snapshot = try await stateContext.multimodalSnapshot(session: input.sessionID, names: names)
                requestedStates = names
                resourceBindings = snapshot.resourceBindings
                imageScopes = Dictionary(
                    uniqueKeysWithValues: snapshot.images.compactMap { image in
                        image.resourceScope.map { (image.id, $0) }
                    })
                let imageProjection = try AgentChatContextBuilder.applyingStateImages(
                    snapshot.images, to: stateMessages, user: userIntent, supportsImages: await chat.supportsImages)
                stateMessages = imageProjection.messages
                ephemeralImageIDs = imageProjection.ephemeralIDs
                let agentData = try JSONEncoder().encode(
                    decisionContext.state.skillState?.contextSnapshot(session: input.sessionID))
                let contextTemplates = try AgentPrompts.requestContext()
                var block = try contextTemplates.render(
                    "facts",
                    variables: [
                        "agent": String(decoding: agentData, as: UTF8.self),
                        "state": String(decoding: snapshot.facts, as: UTF8.self),
                    ])
                if let manifest = imageProjection.manifest {
                    block += try contextTemplates.render("images", variables: ["manifest": manifest])
                }
                if let waiting = inputInteractions[input.id]?.first(where: { $0.scope.executor == .writer }),
                    let current = decisionContext.state.taskViews?[waiting.scope.id], !current.terminal,
                    current.interactionID == waiting.interactionID
                {
                    let question = String(decoding: try JSONEncoder().encode(current.text), as: UTF8.self)
                    block += try promptTemplates.render("writerQuestion", variables: ["question": question])
                }
                guard block.utf8.count <= 16 * 1024 else { throw CommunicationError.capacityExceeded }
                block += try Self.writerFacts(
                    from: decisionContext.state.taskViews ?? [:], dialog: decisionContext.state.history.current.id,
                    budget: min(3_072, 16 * 1024 - block.utf8.count), templates: promptTemplates)
                let system = try State.systemPrompt(
                    catalog, skills: decisionContext.state.skillState, communication: communicationPolicy)
                stateMessages.removeAll { $0.role == .system }
                stateMessages.insert(.init(role: .system, content: system), at: 0)
                // Keep the stable instructions/history prefix ahead of facts that change every request.
                // A native call/result group must remain contiguous.
                let factIndex = stateMessages.last?.role == .user ? stateMessages.count - 1 : stateMessages.count
                stateMessages.insert(.init(role: .system, content: block), at: factIndex)
                stateMessageCount += 1
            }
            let providerMessages = try AgentChatContextBuilder.retainingRecent(
                stateMessages, preservingUser: userIntent,
                protectedSuffixCount: protectedSuffixCount + stateMessageCount,
                protectedImageIDs: ephemeralImageIDs)
            let requestTools: [ChatToolDefinition] =
                await chat.supportsToolCalls
                ? try catalog.tools.compactMap { registration in
                    guard let definition = registration.definition else { return nil }
                    return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
                } : []
            let providerRequest = try ChatRequest(
                messages: providerMessages,
                context: request.context,
                maximumOutputTokens: request.maximumOutputTokens, temperature: request.temperature,
                tools: usesSkills ? requestTools : request.tools
            )
            try await conversations.beginModelRequest(
                .init(
                    id: requestID, input: inputText,
                    requestJSON: try Self.historyRequest(providerRequest.messages, imageScopes: imageScopes),
                    decisionMetadata: try decisionMetadata(
                        skills: decisionContext.state.skillState, states: requestedStates),
                    historyTaskID: decisionContext.state.skillState?.activeTaskID),
                for: input.id, awaitingDispatch: true)
            try beginReplyTurn(input)
            var generationError: (any Error)?
            let text: String
            do {
                text = try await collect(providerRequest, input: input, using: chat)
            } catch {
                try Task.checkCancellation()
                guard !(error is CancellationError), lifecycle == .running else { throw error }
                if fullDuplex {
                    let history = try await conversations.readCurrent()
                    if history.current.turns.first(where: { $0.id == input.id })?.modelRequests?.last?.awaitingDispatch
                        == true
                    {
                        throw error
                    }
                }
                generationError = error
                text = ""
            }
            try await conversations.finishModelRequest(
                input.id, reason: generationError == nil ? generationFinishReason : "error",
                error: generationError.map { Self.failureDescription($0) })
            try roundCoordinator?.seal()
            let completedBudget = budget
            try await contextRepository.update {
                if let completedBudget { try $0.recordBudget(completedBudget, for: input.id) }
                try $0.transitionWork(input.id, to: .awaitingFeedback)
            }
            guard let roundID, emit(.roundFinished(roundID), for: input) else { throw HarnessError.queueFull }
            if fullDuplex {
                guard pendingRounds.count < 32 else { throw HarnessError.queueFull }
                pendingRounds[roundID] = PendingRound(
                    input: input, initial: initial, text: text, userIntent: userIntent, chat: chat,
                    generationError: generationError, ordinal: currentOrdinal, budget: budget,
                    requestTaskID: decisionContext.state.skillState?.activeTaskID,
                    catalog: requestCatalog, capabilities: modelCapabilities, skillIDs: requestSkillIDs,
                    coordinator: roundCoordinator, calls: roundCalls, receipt: roundReceipt, resultBytes: resultBytes,
                    deferred: deferredCommunications, finishReason: generationFinishReason,
                    bindings: resourceBindings, imageScopes: imageScopes, imageIDs: ephemeralImageIDs)
                try await publishPendingResults(roundID)
                throw RoundSuspended()
            }
            while roundReceipt == nil {
                try Task.checkCancellation()
                if let feedbackFailure { throw CapabilityError.invalidRequest(feedbackFailure) }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try await completeRound(
                initial, input: input, using: chat, text: text,
                userIntent: userIntent, generationError: generationError)
        }
    }
    private func completeRound(
        _ initial: ChatRequest, input: AgentInput, using chat: any ChatCapability,
        text: String, userIntent: String, generationError initialError: (any Error)?
    ) async throws -> ChatRequest? {
        var request = initial
        var generationError = initialError
        guard let completedRoundID = roundID else { throw CommunicationError.scopeClosed }
        if let failure = roundReceipt?.failure {
            guard let previous = generationError, roundCalls.allSatisfy({ $0.result != nil }) else {
                throw CapabilityError.invalidRequest(failure)
            }
            generationError = AgentChatRoundFailure(cause: previous, cleanup: failure)
        }
        let deferred = deferredCommunications
        deferredCommunications.removeAll()
        for (id, path, arguments, native) in deferred where !(generationError is CancellationError) {
            let result = try await modelCommunication(path: path, arguments: arguments, input: input)
            guard let index = roundCalls.firstIndex(where: { $0.id == id }) else {
                throw CommunicationError.scopeClosed
            }
            if native {
                try await conversations.recordToolOutcome(
                    id, for: input.id,
                    state: result.isCancellationOnly ? .cancelled : (result.hasFailure ? .failed : .completed),
                    output: result.value, error: result.failureCode)
            }
            try acceptResult(
                ToolResult(
                    callID: id, value: result.value,
                    isError: result.isError, failureCode: result.failureCode, completion: result.completion),
                at: index)
        }
        guard roundCalls.allSatisfy({ $0.result != nil }) else {
            throw CapabilityError.invalidRequest("Round sealed with missing execution feedback")
        }
        let journal = try JSONSerialization.data(
            withJSONObject: roundCalls.map { call -> [String: Any] in
                guard let result = call.result else { throw CommunicationError.invalidPayload }
                var record: [String: Any] = [
                    "callID": call.id, "path": call.path, "protocol": call.tool ? "tool" : "action",
                    "requiresReasoning": !isInternalRuntimeCall(call) && result.requiresReasoning,
                    "internal": isInternalRuntimeCall(call), "result": try Self.observationText(result),
                ]
                if let action = call.actionResult {
                    record["executionID"] = action.executionID
                    record["status"] = action.status.rawValue
                    record["effect"] = action.effect.rawValue
                }
                if let native = call.native { record["providerID"] = native.id }
                return record
            }, options: [.sortedKeys])
        try await conversations.recordGenerationRound(
            .init(id: completedRoundID, resultsJSON: String(decoding: journal, as: UTF8.self)), for: input.id)
        if let generationError { throw generationError }
        if let failed = roundCalls.first(where: { isInternalRuntimeCall($0) && $0.result?.hasFailure == true }),
            let result = failed.result,
            !roundCalls.contains(where: { !isInternalRuntimeCall($0) && $0.result?.requiresReasoning == true })
        {
            throw CapabilityError.unavailable(
                "Internal execution failed at \(failed.path): \(try Self.observationText(result))")
        }
        try await releaseDelegations(parent: input)
        if let skills = try await contextRepository.snapshot().state.skillState,
            let id = skills.activeTaskID, let task = skills.tasks.first(where: { $0.id == id }),
            ["finishing", "cancelling"].contains(task.status)
        {
            if let generationError { throw generationError }
            if let failed = roundCalls.first(where: { $0.result?.hasFailure == true }), let result = failed.result {
                throw CapabilityError.invalidRequest(
                    "Task closure failed at \(failed.path): \(try Self.observationText(result))")
            }
            let cancelled = task.status == "cancelling"
            try await finishLocalDecision(input: input, failed: false, taskBoundaryOnly: true)
            if cancelled || task.continueDecision != true { return nil }
        }
        guard roundCalls.contains(where: { !isInternalRuntimeCall($0) && $0.result?.requiresReasoning == true })
        else {
            return nil
        }
        if fullDuplex {
            for (index, call) in roundCalls.enumerated()
            where !call.tool && call.modelGenerated && !call.forwarded && call.result?.requiresReasoning == true {
                try await enqueueActionResult(
                    call, input: input, chat: chat)
                roundCalls[index].forwarded = true
            }
            let tools = roundCalls.filter(\.tool)
            if tools.contains(where: { !$0.forwarded && $0.result?.requiresReasoning == true }) {
                try await enqueueNativeResults(tools, input: input, round: completedRoundID, text: text, chat: chat)
            }
            return nil
        }
        var messages = request.messages
        let native = roundCalls.compactMap(\.native)
        if !text.isEmpty || !native.isEmpty {
            messages.append(ChatMessage(role: .assistant, content: text, toolCalls: native))
        }
        for call in roundCalls where call.tool {
            guard let native = call.native, let result = call.result else {
                throw CommunicationError.invalidPayload
            }
            messages.append(
                ChatMessage(
                    role: .tool,
                    content: try AgentChatContextBuilder.nativeObservation(result, rejection: call.rejection),
                    toolCallID: native.id))
        }
        messages += try roundActionResultMessages()
        do {
            messages += try await observations(
                roundCalls.compactMap { call in
                    guard !isInternalRuntimeCall(call), let result = call.result, result.requiresReasoning else {
                        return nil
                    }
                    return AgentChatObservation(path: call.path, result: result)
                }, input, chat)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        let additions = messages.dropFirst(request.messages.count)
        roundContinuationInputText = additions.filter { $0.role != .assistant }.map(\.content).joined(
            separator: "\n")
        roundSuffixCount = max(1, additions.count)
        request = try ChatRequest(
            messages: try AgentChatContextBuilder.retainingRecent(
                messages, preservingUser: userIntent, protectedSuffixCount: roundSuffixCount),
            context: initial.context,
            maximumOutputTokens: initial.maximumOutputTokens, temperature: initial.temperature, tools: initial.tools
        )
        return request
    }

    /// Actual Action outcomes survive context reconstruction; no private Task/Skill state summary.
    private func roundActionResultMessages() throws -> [ChatMessage] {
        let actions = try roundCalls.enumerated().filter {
            !$0.element.tool && !isInternalRuntimeCall($0.element) && $0.element.result?.requiresReasoning == true
        }.map { index, call -> [String: Any] in
            guard let result = call.result else { throw CommunicationError.invalidPayload }
            return AgentChatContextBuilder.actionObservation(
                index: index + 1, name: observationName(call), result: result,
                action: call.actionResult, rejection: call.rejection)
        }
        guard !actions.isEmpty else { return [] }
        let data = try JSONSerialization.data(withJSONObject: actions, options: [.sortedKeys])
        return [
            .init(
                role: .user,
                content: try promptTemplates.render(
                    "executionObservations", variables: ["data": String(decoding: data, as: UTF8.self)]))
        ]
    }
    private func isInternalRuntimeCall(_ call: RoundCall) -> Bool {
        !call.modelGenerated
    }
    private func observationName(_ call: RoundCall) -> String {
        call.rejection?.alias
            ?? requestCatalog?.actions.first(where: { $0.path.description == call.path })?.alias ?? call.path
    }

    private struct HistoryImageReference: Encodable {
        let id: String
        let mimeType: String
        let byteCount: Int
        let resourceScope: String?
    }
    private struct HistoryRequestMessage: Encodable {
        let role: ChatMessage.Role
        let content: String
        let toolCalls: [ChatToolCall]
        let toolCallID: String?
        let imageReferences: [HistoryImageReference]
    }
    private static func historyRequest(_ messages: [ChatMessage], imageScopes: [String: String] = [:]) throws -> String
    {
        let records = messages.map { message in
            HistoryRequestMessage(
                role: message.role, content: message.content, toolCalls: message.toolCalls,
                toolCallID: message.toolCallID,
                imageReferences: (message.images ?? []).map {
                    HistoryImageReference(
                        id: $0.id, mimeType: $0.mimeType, byteCount: $0.data.count, resourceScope: imageScopes[$0.id])
                })
        }
        return String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    }

    private func persistFeedback(_ input: AgentInput) async throws {
        do { try await prepareSignal(input) } catch {
            feedbackFailure = "Execution feedback persistence failed: \(error)"
            throw error
        }
    }
    private func acceptPendingFeedback(_ input: AgentInput) async throws -> Bool {
        let key: String?
        switch input.payload {
        case .roundResult(let value): key = value.roundID
        case .actionResult(let value): key = value.roundID
        case .toolResult(let value):
            key =
                value.roundID ?? pendingRounds.first(where: { $0.value.calls.contains { $0.id == value.callID } })?.key
        default: return false
        }
        guard let key, let pending = pendingRounds[key] else { return false }
        guard input.metadata.origin == .runtime, input.metadata.source == "runtime",
            input.sessionID == pending.input.sessionID, input.metadata.parentID == pending.input.id,
            input.metadata.rootID == pending.input.metadata.rootID, input.turn == pending.input.turn
        else {
            throw CommunicationError.unauthorized
        }
        try await persistFeedback(input)
        guard var current = pendingRounds[key] else { return true }
        switch input.payload {
        case .roundResult(let value):
            guard current.receipt == nil else { throw CommunicationError.unauthorized }
            current.receipt = value
        case .toolResult(let value):
            guard let index = current.calls.firstIndex(where: { $0.tool && $0.id == value.callID && $0.result == nil })
            else { throw CommunicationError.unauthorized }
            try await conversations.recordToolOutcome(
                value.callID, for: current.input.id,
                state: value.isCancellationOnly ? .cancelled : (value.hasFailure ? .failed : .completed),
                output: value.value, error: value.failureCode)
            guard let latest = pendingRounds[key] else { return true }
            current = latest
            guard current.calls[index].result == nil else { throw CommunicationError.unauthorized }
            try current.coordinator?.accept(value, roundID: key)
            current.calls[index].result = value
            current.calls[index].completedAt = Date()
        case .actionResult(let value):
            guard value.owner.agent == descriptor.id, value.owner.sessionID == input.sessionID,
                let index = current.calls.firstIndex(where: { !$0.tool && $0.id == value.callID && $0.result == nil }),
                current.calls[index].path == value.path.description
            else { throw CommunicationError.unauthorized }
            let result = ToolResult(
                callID: current.calls[index].id, value: try Self.completionText(value.completion),
                isError: value.status != .succeeded, failureCode: value.failure?.rawValue,
                completion: value.completion ?? .completed, roundID: key)
            try current.coordinator?.accept(result, roundID: key)
            current.calls[index].result = result
            current.calls[index].actionResult = value
            current.calls[index].completedAt = Date()
            resultInbox.accept(value)
        default: return false
        }
        current.resultBytes = try current.calls.compactMap(\.result).reduce(0) {
            try $0 + Self.observationText($1).utf8.count
        }
        if current.resultBytes > 65_536 { throw CommunicationError.invalidPayload }
        pendingRounds[key] = current
        try await publishPendingResults(key)
        if lifecycle == .running { drain() }
        return true
    }

    /// Per-call Action results are ready independently of other output channels.
    /// The flag owns publication across suspension points and prevents settlement from overtaking it.
    private func publishPendingResults(_ key: String) async throws {
        guard var pending = pendingRounds[key], !pending.publishing else { return }
        pending.publishing = true
        pendingRounds[key] = pending
        do {
            while let current = pendingRounds[key], !current.cancelled,
                let index = current.calls.firstIndex(where: {
                    !$0.tool && $0.modelGenerated && !$0.forwarded && $0.result?.requiresReasoning == true
                })
            {
                try await enqueueActionResult(
                    current.calls[index], input: current.input, chat: current.chat, pendingKey: key)
                pendingRounds[key]?.calls[index].forwarded = true
            }
            if let current = pendingRounds[key], !current.cancelled {
                let tools = current.calls.filter(\.tool)
                if tools.allSatisfy({ $0.result != nil }),
                    tools.contains(where: { !$0.forwarded && $0.result?.requiresReasoning == true })
                {
                    try await enqueueNativeResults(
                        tools, input: current.input, round: key,
                        text: current.text, chat: current.chat, pendingKey: key)
                    for index in current.calls.indices where current.calls[index].tool {
                        pendingRounds[key]?.calls[index].forwarded = true
                    }
                }
            }
        } catch {
            pendingRounds[key]?.publishing = false
            // Admission/attachment failure is explicit. The result remains unforwarded for settlement.
            emitFailure(error, for: pending.input)
        }
        guard var current = pendingRounds[key] else { return }
        current.publishing = false
        if current.receipt != nil, !current.queued {
            try queue.admit(current.input, disposition: .enqueue(priority: 100))
            current.queued = true
        }
        pendingRounds[key] = current
    }

    private func enqueueActionResult(
        _ call: RoundCall, input: AgentInput, chat: any ChatCapability, pendingKey: String? = nil
    ) async throws {
        guard let result = call.result, result.requiresReasoning else { return }
        let observation = AgentChatContextBuilder.compactResult(
            result, action: call.actionResult, rejection: call.rejection)
        let content = String(
            decoding: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), as: UTF8.self)
        let payload = InputPayload.text(content)
        let candidate = AgentInput(
            id: call.id + ".result", sessionID: input.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "action." + call.path, origin: .runtime,
                rootID: input.metadata.rootID, parentID: input.id))
        let semantic = try makeSemanticMessage(
            input: candidate, role: .action, channel: "action." + call.path, content: content, time: call.completedAt)
        let attachments = try await observations([.init(path: call.path, result: result)], input, chat)
        try Task.checkCancellation()
        if let pendingKey {
            guard let pending = pendingRounds[pendingKey], !pending.cancelled else { throw CancellationError() }
        }
        try await receiveSignal(candidate, semantic: semantic, attachments: attachments)
    }

    private func enqueueNativeResults(
        _ calls: [RoundCall], input: AgentInput, round: String, text: String, chat: any ChatCapability,
        pendingKey: String? = nil
    ) async throws {
        var attachments = [ChatMessage(role: .assistant, content: text, toolCalls: calls.compactMap(\.native))]
        for call in calls {
            guard let native = call.native, let result = call.result else { throw CommunicationError.invalidPayload }
            attachments.append(
                .init(
                    role: .tool,
                    content: try AgentChatContextBuilder.nativeObservation(result, rejection: call.rejection),
                    toolCallID: native.id))
        }
        attachments += try await observations(
            calls.compactMap { call in
                guard let result = call.result, result.requiresReasoning else { return nil }
                return .init(path: call.path, result: result)
            }, input, chat)
        let content = "See the paired tool results."
        let payload = InputPayload.text(content)
        let candidate = AgentInput(
            id: round + ".tools", sessionID: input.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "action.tools", origin: .runtime,
                rootID: input.metadata.rootID, parentID: input.id))
        let semantic = try makeSemanticMessage(
            input: candidate, role: .action, channel: "action.tools",
            content: content, time: calls.compactMap(\.completedAt).max())
        try Task.checkCancellation()
        if let pendingKey {
            guard let pending = pendingRounds[pendingKey], !pending.cancelled else { throw CancellationError() }
        }
        try await receiveSignal(candidate, semantic: semantic, attachments: attachments)
    }

    private func validateFeedback(_ input: AgentInput) throws {
        guard let activeInput, roundID != nil, input.metadata.origin == .runtime,
            input.metadata.source == "runtime", input.sessionID == activeInput.sessionID,
            input.metadata.parentID == activeInput.id, input.metadata.rootID == activeInput.metadata.rootID,
            input.turn == activeInput.turn
        else { throw CommunicationError.unauthorized }
    }
    private func acceptResult(_ result: ToolResult, at index: Int) throws {
        guard roundCalls.indices.contains(index), roundCalls[index].id == result.callID, roundCalls[index].result == nil
        else { throw CommunicationError.unauthorized }
        let bytes = try Self.observationText(result).utf8.count
        guard resultBytes + bytes <= 65_536 else {
            feedbackFailure = "Generation feedback exceeds 64 KiB"
            throw CommunicationError.invalidPayload
        }
        guard let roundID else { throw CommunicationError.scopeClosed }
        try roundCoordinator?.accept(result, roundID: roundID)
        resultBytes += bytes
        roundCalls[index].result = result
        roundCalls[index].completedAt = Date()
    }
    private func retireRound() {
        roundCalls.removeAll()
        deferredCommunications.removeAll()
        roundReceipt = nil
    }
    private static func completionText(_ completion: AgentActionCompletion?) throws -> String {
        switch completion {
        case .value(let value): return value
        case .completed: return "completed"
        case .activityStarted(let id): return "activityStarted:\(id)"
        case .activityStopped(let id): return "activityStopped:\(id)"
        case .report(let report): return report.failureDescription ?? report.status.rawValue
        case nil: return "No completion value"
        }
    }
    private static func observationText(_ result: ToolResult) throws -> String {
        guard
            result.hasFailure
                || {
                    if case .report = result.completion { true } else { false }
                }()
        else { return result.value }
        var object: [String: Any] = ["isError": result.hasFailure, "value": result.value]
        if let code = result.failureCode { object["failureCode"] = code }
        if case .report(let report) = result.completion {
            object["report"] =
                [
                    "status": report.status.rawValue,
                    "entries": report.entries.map { entry -> [String: Any] in
                        var leaf: [String: Any] = [
                            "path": entry.path, "status": entry.status.rawValue, "details": entry.details,
                        ]
                        if let code = entry.code { leaf["code"] = code.rawValue }
                        return leaf
                    },
                    "executionFailure": report.executionFailure?.rawValue ?? NSNull(),
                    "failureDescription": report.failureDescription ?? NSNull(),
                ] as [String: Any]
        }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    @discardableResult
    private func emitAction(_ call: ActionCall, for input: AgentInput, modelGenerated: Bool = false) throws -> Bool {
        guard roundID != nil, activeInput?.id == input.id else { return emit(.actionCall(call), for: input) }
        guard roundCalls.count < 120 else { throw GenerationError.limitExceeded }
        let id = UUID().uuidString

        try roundCoordinator?.register(id: id)
        roundCalls.append(
            .init(id: id, path: call.actionPath.description, tool: false, native: nil, modelGenerated: modelGenerated))
        return emit(.actionCall(call), for: input, callID: id)
    }

    private func modelEvidence(_ event: ChatEvent, input: AgentInput) async throws {
        switch event {
        case .text: break
        case .usage(let usage):
            try await recordGenerationEvidence {
                try await conversations.recordTokenUsage(
                    .init(
                        input: usage.input, generated: usage.generated, total: usage.total,
                        cachedInput: usage.cachedInput, cacheWriteInput: usage.cacheWriteInput), for: input.id)
            }
        case .finished(let reason):
            switch reason {
            case .stop: generationFinishReason = "stop"
            case .lengthLimit: generationFinishReason = "lengthLimit"
            case .toolCalls: generationFinishReason = "toolCalls"
            }
        case .toolCall: break
        }
    }
    private func recordGenerationEvidence(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch {
            feedbackFailure = "Generation history update failed: \(error)"
            throw error
        }
    }
    /// Presentation calls participate in the round, but never count as a model-generated answer.
    private func finishReplyWaiting(_ requestID: String, input: AgentInput) async throws {
        guard replyWaitingRequest == requestID else { return }
        replyWaitingRequest = nil
        await replyPresentation?(false)
        guard reportsReplyActivity, input.turn != nil else { return }
        // Cancellation closes the round; reply occupancy/lifecycle clears its UI projection.
        guard !Task.isCancelled else { return }
        guard
            try emitAction(
                Self.replyWaiting.call(["enabled": "false", "requestID": requestID]), for: input)
        else { throw HarnessError.queueFull }
    }
    private func dispatchRequest(_ input: AgentInput) async throws {
        try await conversations.markModelRequestDispatched(input.id)
        interruptedIntents[input.sessionID] = nil
    }

    private func collect(_ request: ChatRequest, input: AgentInput, using chat: any ChatCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let requestID = UUID().uuidString
        if reportsReplyActivity, input.turn != nil {
            guard
                try emitAction(
                    Self.replyWaiting.call(["enabled": "true", "requestID": requestID]), for: input)
            else { throw HarnessError.queueFull }
            replyWaitingRequest = requestID
        }
        if let replyPresentation {
            replyWaitingRequest = requestID
            await replyPresentation(true)
        }
        var request = request
        request.onDispatch = { [self] in
            try await self.dispatchRequest(input)
        }
        let startCalls = generationCalls
        let result: Result<String, any Error>
        do {
            result = .success(
                try await AgentChatDriver.collect(
                    request, using: chat,
                    consumers: .init(
                        text: { try await self.consumeActionText($0, input: input) },
                        native: { _ = try await self.consumeNativeTools($0, input: input) },
                        evidence: { event in
                            try await self.dispatchRequest(input)
                            switch event {
                            case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                                await self.appendDecisionReply(text)
                                try await self.finishReplyWaiting(requestID, input: input)
                            case .toolCall, .finished:
                                try await self.finishReplyWaiting(requestID, input: input)
                            default: break
                            }
                            try await self.modelEvidence(event, input: input)
                        },
                        recording: { evidence in
                            if let update = evidence.transport {
                                try await self.conversations.recordModelTransport(update, for: input.id)
                                return
                            }
                            try await self.conversations.recordModelExchange(
                                requestJSON: evidence.requestJSON, response: evidence.responseJSON, for: input.id,
                                initial: evidence.initial)
                        },
                        timing: { timing in
                            try await self.recordGenerationEvidence {
                                try await self.conversations.recordModelTiming(
                                    startedAt: timing.startedAt, firstTokenAt: timing.firstTokenAt,
                                    latency: timing.firstTokenLatency, for: input.id)
                            }
                        })))
        } catch {
            result = .failure(error)
        }
        // Runs for errors before a stream exists as well as cancellation of a live stream.
        try await finishReplyWaiting(requestID, input: input)
        let answer = try result.get()
        guard generationCalls > startCalls else {
            throw CapabilityError.unavailable("LLM returned no speakable answer")
        }
        return answer
    }

    private func consumeActionText(_ fragments: AsyncThrowingStream<String, any Error>, input: AgentInput)
        async throws -> String
    {
        let catalog = requestCatalog ?? modelCapabilities
        var generator = AgentGenerator(
            capabilities: catalog, textMapping: Self.mapText,
            segmentation: try Self.textSegmentation)
        var text = ""
        var emittedCalls = 0
        for try await delta in fragments {
            try Task.checkCancellation()
            try await recordGenerationEvidence { try await conversations.append(delta, to: input.id) }
            text += delta
            try await emitFunctions(generator.append(delta), for: input, count: &emittedCalls)
        }
        try Task.checkCancellation()
        try await emitFunctions(generator.finish(), for: input, count: &emittedCalls)
        return text
    }

    private func consumeNativeTools(_ calls: AsyncThrowingStream<ChatToolCall, any Error>, input: AgentInput)
        async throws -> String
    {
        let catalog = requestCatalog ?? modelCapabilities
        var emittedCalls = 0
        for try await native in calls {
            try Task.checkCancellation()
            let callID = UUID().uuidString
            try await recordGenerationEvidence {
                try await conversations.recordToolCall(
                    ModelToolCall(
                        id: callID, providerID: native.id, name: native.name,
                        argumentsJSON: native.argumentsJSON), for: input.id)
            }
            let call: ToolCall
            do {
                call = try ToolCallParser.parse(
                    id: callID, alias: native.name, argumentsJSON: Data(native.argumentsJSON.utf8),
                    capabilities: catalog)
                if AgentCommunicationAdapter.isCommunication(call.toolPath) {
                    guard !roundCalls.contains(where: { $0.native?.id == native.id })
                    else { throw GenerationError.limitExceeded }
                    try budget?.reserveNativeCall()
                    try roundCoordinator?.register(id: call.id)
                    roundCalls.append(
                        .init(id: call.id, path: call.toolPath, tool: true, native: native))
                    if call.arguments["kind"] == "result" {
                        deferredCommunications.append((call.id, call.toolPath, call.arguments, true))
                        try reserveGeneratedCall(count: &emittedCalls)
                        continue
                    }
                    let result = try await modelCommunication(
                        path: call.toolPath, arguments: call.arguments, input: input)
                    try await recordGenerationEvidence {
                        try await conversations.recordToolOutcome(
                            call.id, for: input.id,
                            state: result.isCancellationOnly ? .cancelled : (result.hasFailure ? .failed : .completed),
                            output: result.value,
                            error: result.failureCode)
                    }
                    try acceptResult(
                        ToolResult(
                            callID: call.id, value: result.value,
                            isError: result.isError, failureCode: result.failureCode, completion: result.completion),
                        at: roundCalls.count - 1)
                    try reserveGeneratedCall(count: &emittedCalls)
                    continue
                }
                guard !roundCalls.contains(where: { $0.native?.id == native.id })
                else {
                    throw GenerationError.limitExceeded
                }
                try budget?.reserveNativeCall()

                try roundCoordinator?.register(id: call.id)
                roundCalls.append(
                    .init(id: callID, path: call.toolPath, tool: true, native: native))
                try await emitFunctions([.tool(call)], for: input, count: &emittedCalls)
            } catch {
                do {
                    try await recordGenerationEvidence {
                        try await conversations.recordToolOutcome(
                            callID, for: input.id, state: .failed, error: String(describing: error))
                    }
                } catch {
                    try Task.checkCancellation()
                    emit(.control("agent.historyError: \(error)"), for: input)
                    throw error
                }
                guard let reason = error as? GenerationError,
                    reason == .unknownCapability || reason == .invalidParameters
                else { throw error }
                guard !roundCalls.contains(where: { $0.native?.id == native.id })
                else {
                    throw GenerationError.limitExceeded
                }
                try budget?.reserveNativeCall()
                let path =
                    catalog.tools.first(where: { $0.alias == native.name })?.path ?? native.name

                try roundCoordinator?.register(id: callID)
                roundCalls.append(
                    .init(
                        id: callID, path: path, tool: true, native: native,
                        rejection: CallRejection(kind: .tool, alias: native.name, callID: callID, reason: reason)))
                try acceptResult(
                    .init(
                        callID: callID,
                        value: invocationRejectionValue(
                            CallRejection(kind: .tool, alias: native.name, callID: callID, reason: reason)),
                        isError: true,
                        failureCode: AgentCommunicationAdapter.isCommunication(path)
                            ? "communicationRejected" : "invalidInvocation"), at: roundCalls.count - 1)
                try await emitFunctions(
                    [.rejected(CallRejection(kind: .tool, alias: native.name, callID: callID, reason: reason))],
                    for: input, count: &emittedCalls)
            }
        }
        try Task.checkCancellation()
        return ""
    }
    private func emitImmediate(_ text: String, for input: AgentInput) async {
        defer {
            worker = nil
            activeInput = nil
            finishHostCancellation(input)
            drain()
        }
        do {
            let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
            let batch = try selection.batch()
            try await contextRepository.update {
                try $0.consume(batch, retainingLast: 4096)
                if $0.work[input.id] == nil { try $0.beginWork(input.id, sessionID: input.sessionID) }
                try $0.transitionWork(input.id, to: .running)
            }
            try beginReplyTurn(input)
            guard text.utf8.count <= 16_384 else { throw CapabilityError.eventTooLarge }
            var generator = AgentGenerator(
                capabilities: modelCapabilities, textMapping: Self.mapText,
                segmentation: try Self.textSegmentation)
            var count = 0
            try await emitFunctions(
                generator.append(AgentGenerator.escapeText(text)) + generator.finish(), for: input, count: &count)
            try await contextRepository.update { try $0.transitionWork(input.id, to: .completed) }
            emit(.control("agent.finished"), for: input)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            do {
                try await contextRepository.update {
                    if $0.work[input.id]?.state.terminal == false {
                        try $0.transitionWork(input.id, to: cancelled ? .cancelled : .failed)
                    }
                }
            } catch { emit(.control("agent.historyError: \(error)"), for: input) }
            if !Task.isCancelled {
                if cancelled {
                    emit(.control("agent.cancelled"), for: input)
                } else {
                    emitFailure(error, for: input)
                }
            }
        }
    }
    private func reserveGeneratedCall(count: inout Int) throws {
        guard count < 120 else { throw GenerationError.limitExceeded }
        if roundID != nil {
            guard generationCalls < 120 else { throw GenerationError.limitExceeded }
            generationCalls += 1
        }
        count += 1
    }

    private func invocationRejectionValue(_ rejection: CallRejection) -> String {
        let correction =
            rejection.reason == .unknownCapability
            ? "This alias is absent from this request's catalog. Use only current aliases; historical calls do not grant capabilities."
            : "Use the parameter names and required values declared in this request's catalog."
        let loading =
            usesSkills
            ? " If the operation needs an unloaded Skill, use a registered Skill control, await its committed result, then use the next request's catalog. Do not guess replacement aliases."
            : ""
        return "\(rejection.reason): rejected \(rejection.kind) alias '\(rejection.alias)' before execution. "
            + "No function was executed for this rejected call. " + correction + loading
    }

    private func emitFunctions(_ calls: [GenerationEvent], for input: AgentInput, count: inout Int) async throws {
        for event in calls {
            if case .rejected(let rejection) = event {
                try Task.checkCancellation()
                try reserveGeneratedCall(count: &count)
                if rejection.kind == .action, roundID != nil {
                    let path =
                        modelCapabilities.actions.first(where: { $0.alias == rejection.alias })?.path.description
                        ?? rejection.alias

                    let id = UUID().uuidString
                    try roundCoordinator?.register(id: id)
                    roundCalls.append(
                        .init(
                            id: id, path: path, tool: false,
                            native: nil, rejection: rejection))
                    try acceptResult(
                        .init(
                            callID: id, value: invocationRejectionValue(rejection), isError: true,
                            failureCode: AgentCommunicationAdapter.isCommunication(path)
                                ? "communicationRejected" : "invalidInvocation"), at: roundCalls.count - 1)
                }
                guard emit(.rejectedCall(rejection), for: input) else { throw HarnessError.queueFull }
                continue
            }
            if case .scheduling(let directive) = event {
                try Task.checkCancellation()
                guard emit(.scheduling(directive), for: input) else { throw HarnessError.queueFull }
                continue
            }
            if case .tool(let call) = event {
                try Task.checkCancellation()
                try reserveGeneratedCall(count: &count)
                guard emit(.toolCall(call), for: input, callID: roundID == nil ? nil : call.id) else {
                    throw HarnessError.queueFull
                }
                try await recordSkillUse(path: call.toolPath, callType: "tool", input: input)
                continue
            }
            guard let original = event.actionCall else { continue }
            let modelGenerated: Bool
            if case .action = event { modelGenerated = true } else { modelGenerated = false }
            let call = original
            if AgentCommunicationAdapter.isCommunication(call.actionPath.description) {
                try reserveGeneratedCall(count: &count)
                let id = UUID().uuidString
                try roundCoordinator?.register(id: id)
                if roundID != nil {
                    roundCalls.append(
                        .init(
                            id: id, path: call.actionPath.description,
                            tool: false, native: nil, modelGenerated: modelGenerated))
                }
                if call.parameters["kind"] == "result", roundID != nil {
                    deferredCommunications.append((id, call.actionPath.description, call.parameters, false))
                    continue
                }
                let result = try await modelCommunication(
                    path: call.actionPath.description,
                    arguments: call.parameters, input: input)
                if roundID != nil {
                    try acceptResult(
                        ToolResult(
                            callID: id, value: result.value,
                            isError: result.isError, failureCode: result.failureCode, completion: result.completion),
                        at: roundCalls.count - 1)
                }
                continue
            }
            try Task.checkCancellation()
            guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
            try reserveGeneratedCall(count: &count)
            if call.actionPath == ActionPath(domain: "Speech", module: "Playback", function: "speak"),
                let text = call.parameters["text"]
            {
                try await emitPlayback(text, for: input, modelGenerated: modelGenerated)
                continue
            }
            guard try emitAction(call, for: input, modelGenerated: modelGenerated) else { throw HarnessError.queueFull }
            try await recordSkillUse(path: call.actionPath.description, callType: "action", input: input)
        }
    }

    private func emitPlayback(_ text: String, for input: AgentInput, modelGenerated: Bool = false) async throws {
        guard let speechOutput else { throw CapabilityError.unavailable("Speech output not configured") }
        let audioID = try await speechOutput.prepare(text: text, input: input)
        do {
            try Task.checkCancellation()
            let call = try Self.playback.call(["audioID": audioID])
            guard try emitAction(call, for: input, modelGenerated: modelGenerated) else { throw HarnessError.queueFull }
        } catch {
            do { try await speechOutput.cancel(audioID: audioID, input: input) } catch let cleanup {
                throw AgentFailure(
                    component: "assistant", operation: "speech.submit", underlying: error, cleanupErrors: [cleanup])
            }
            throw error
        }
    }

    private func recordSkillUse(path: String, callType: String, input: AgentInput) async throws {
        guard usesSkills, roundID != nil, let catalog = requestCatalog else { return }
        let visible =
            callType == "action"
            ? catalog.actions.contains { $0.path.description == path }
            : catalog.tools.contains { $0.path == path }
        guard visible else { return }
        let snapshotSkills = requestSkillIDs
        try await contextRepository.update {
            try $0.state.skillState?.recordUse(
                path: path, callType: callType, inputID: input.id, snapshotSkills: snapshotSkills)
        }
    }

    private func finishHostCancellation(_ input: AgentInput, force: Bool = false) {
        guard !hostCancellationInProgress || force else { return }
        guard let cancellation = hostCancelledInput, cancellation.id == input.id else { return }
        hostCancelledInput = nil
        replyInputs.remove(input.id)
        if !emit(.control("agent.cancelled"), for: input, terminalRound: cancellation.round) {
            // Explicit bounded rejection: no cancellation success is fabricated for the transport.
            reportHostCancellationFailure = true
        }
    }

    // MARK: - Output

    private static func failureDescription(_ error: any Error) -> String {
        (error as? any ChatFailureProviding)?.chatFailure.description ?? String(describing: error)
    }

    private func emitFailure(_ error: any Error, for input: AgentInput, detail: String? = nil) {
        let cause = (error as? AgentChatRoundFailure)?.cause ?? error
        let diagnostic: AgentFailureDiagnostic
        if let model = cause as? any ChatFailureProviding {
            let cause = model.chatFailure
            diagnostic = .init(
                category: [.httpStatus, .transport].contains(cause.reason) ? .modelTransport : .modelResponse,
                code: "agent.model." + cause.reason.rawValue, detail: detail ?? Self.failureDescription(error))
        } else if let generation = cause as? GenerationError {
            diagnostic = .init(
                category: .generation, code: "agent.generation." + String(describing: generation),
                detail: detail ?? String(describing: generation))
        } else if cause is ContainerContextError {
            diagnostic = .init(
                category: .context, code: "agent.context.snapshot", detail: detail ?? String(describing: error))
        } else {
            diagnostic = .init(
                category: .runtime, code: "agent.runtime.failed", detail: detail ?? String(describing: error))
        }
        emit(.control("agent.error: \(diagnostic.detail)"), for: input, failure: diagnostic)
    }

    @discardableResult
    private func emit(
        _ output: AgentOutput, for input: AgentInput, callID: String? = nil, terminalRound: String? = nil,
        failure: AgentFailureDiagnostic? = nil
    ) -> Bool {
        let completesReply: Bool
        if reportsReplyActivity, case .control(let value) = output {
            completesReply =
                replyInputs.contains(input.id)
                && (value == "agent.finished" || value == "agent.cancelled" || value.hasPrefix("agent.error:"))
        } else {
            completesReply = false
        }
        if completesReply { replyInputs.remove(input.id) }
        outputSequence += 1
        let outputRoundID: String?
        if case .communication = output {
            outputRoundID = nil
        } else {
            outputRoundID = terminalRound ?? (input.id == activeInput?.id ? roundID : nil)
        }
        switch continuation.yield(
            OutputEnvelope(
                source: descriptor.id, context: input.context, output: output, sequence: outputSequence,
                roundID: outputRoundID,
                callID: callID, taskScope: input.taskScope, failure: failure,
                resourceBindings: outputRoundID == nil ? [:] : resourceBindings))
        {
        case .enqueued:
            if completesReply { publishReplyActivity(for: input) }
            return true
        case .dropped, .terminated:
            lifecycle = .failed
            queue.removeAll()
            worker?.cancel()
            continuation.finish()
            return false
        @unknown default:
            lifecycle = .failed
            queue.removeAll()
            worker?.cancel()
            continuation.finish()
            return false
        }
    }

    /// Report complete interaction occupancy; SpeechPerception decides listening policy.
    private func publishReplyActivity(for input: AgentInput, acknowledgingSpeech: Bool = false) {
        guard reportsReplyActivity else { return }
        replyActivityParent = input
        let occupied = !replyInputs.isEmpty || !replyTasks.isEmpty
        if acknowledgingSpeech, case .transcript(_, final: true)? = input.payload.perception {
            acknowledgedSpeech = (input.sessionID, input.metadata.rootID)
        }
        // Every newer snapshot retains the final-speech acknowledgment. Unrelated
        // text or task feedback must not strand the pending ASR gate
        // when their snapshot overtakes the original acknowledgment in transport.
        let acknowledgedRoot: String
        if let acknowledgedSpeech, acknowledgedSpeech.session == input.sessionID {
            acknowledgedRoot = acknowledgedSpeech.root
        } else {
            acknowledgedRoot = input.metadata.rootID
        }
        let needsSpeechAcknowledgement =
            publishedReplyActivity?.root != acknowledgedRoot
            && acknowledgedSpeech?.session == input.sessionID
        // Publish only occupancy transitions and new final-speech acknowledgements.
        // Every emitted value remains a complete snapshot; no admitted input is dropped.
        guard
            publishedReplyActivity?.session != input.sessionID
                || publishedReplyActivity?.occupied != occupied
                || needsSpeechAcknowledgement
        else { return }
        do {
            let activity = ReplyActivity(
                revision: outputSequence + 1, inputs: Array(replyInputs), tasks: Array(replyTasks),
                acknowledgedRoot: acknowledgedRoot)
            let checkpoint =
                "assistant.replyActivity inputs=\(replyInputs.count) tasks=\(replyTasks.count) speechAcknowledged=\(acknowledgedSpeech?.session == input.sessionID)"
            Logger(subsystem: "dev.mobileharness", category: "SpeechListening").notice(
                "\(checkpoint, privacy: .public)")
            let payload = InputPayload.text("Reply activity")
            let fact = AgentInput(
                id: UUID().uuidString,
                sessionID: input.sessionID, payload: payload,
                metadata: InputMetadata(
                    payload: payload, source: input.metadata.source,
                    incarnation: input.metadata.incarnation, origin: input.metadata.origin,
                    rootID: input.metadata.rootID, parentID: input.id))
            let action = try CommunicationAction(message: activity.message)
            if emit(.communication(action), for: fact) {
                publishedReplyActivity = (input.sessionID, occupied, acknowledgedRoot)
                emit(.control("agent.finished"), for: fact)
            }
        } catch { _ = emit(.control("agent.error: reply activity failed: \(error)"), for: input) }
    }

    // MARK: - Communication output

    private func communicate(_ message: AgentMessage, parent: AgentInput, to target: AgentID? = nil) async throws
        -> DeliveryReport
    {
        let signal = message.content(as: AgentTaskSignal.self)
        let durable = signal?.scope.execution == .background && target != nil
        let action = try CommunicationAction(
            id: durable && signal?.kind == .request ? signal?.scope.id : nil, message: message, target: target)
        if durable, let signal, let target, let taskRecords, signal.kind != .request {
            try await requireCommunications().enqueueAgentMessage(
                .init(
                    id: action.id, sender: descriptor.id.rawValue, receiver: target.rawValue,
                    contract: signal.contract, payload: try JSONEncoder().encode(signal),
                    correlationID: signal.scope.id,
                    replyTo: signal.scope.id, dedupeKey: action.id))
        }
        let evidence = try JSONEncoder().encode(
            SignalEvidence(
                AgentInput(
                    id: action.id, sessionID: parent.sessionID, payload: .observation(message),
                    metadata: parent.metadata, turn: parent.turn, taskScope: parent.taskScope)))
        try await contextRepository.update {
            try $0.append(
                .init(
                    id: action.id, taskID: parent.taskScope?.id ?? parent.id,
                    kind: "communication.output", data: evidence))
        }
        try await communicationReceipts.register(action.id)
        if reportsReplyActivity, let task = message.content(as: AgentTaskSignal.self),
            task.scope.execution == .foreground, task.kind == .request || task.kind == .input
        {
            replyTasks.insert(task.scope.id)
            publishReplyActivity(for: parent)
        }
        guard emit(.communication(action), for: parent) else {
            await communicationReceipts.cancel(action.id)
            throw CommunicationError.capacityExceeded
        }
        if target == nil {
            await communicationReceipts.cancel(action.id)
            return DeliveryReport()
        }
        let report = try await communicationReceipts.wait(action.id)
        if durable, let target, let taskRecords {
            if report.delivered.contains(target) {
                try await requireCommunications().receiveAgentMessage(
                    action.id, receiver: target.rawValue, consumed: false)
            } else {
                try await requireCommunications().failAgentMessage(
                    action.id, failure: report.failure ?? report.rejected[target] ?? "Not delivered")
            }
        }
        if reportsReplyActivity, let task = message.content(as: AgentTaskSignal.self),
            !report.rejected.isEmpty || report.failure != nil || report.delivered.isEmpty
        {
            replyTasks.remove(task.scope.id)
            publishReplyActivity(for: parent)
        }
        return report
    }

    // MARK: - Task communication

    public func ownsFeedback(_ input: AgentInput) -> Bool {
        switch input.payload {
        case .communicationReceipt: return true
        case .roundResult(let value): return value.roundID == roundID || pendingRounds[value.roundID] != nil
        case .actionResult(let value):
            return value.roundID != nil
                && (value.roundID == roundID || value.roundID.map { pendingRounds[$0] != nil } == true)
        case .toolResult(let value):
            return roundCalls.contains { $0.id == value.callID }
                || pendingRounds.values.contains { $0.calls.contains { $0.id == value.callID } }
        default: return false
        }
    }

    public func admitFixedTask(_ signal: AgentTaskSignal, input: AgentInput) async throws {
        guard signal.scope.executor == descriptor.id else { throw CommunicationError.unauthorized }
        try await contextRepository.update { try $0.tasks.accept(signal, input: input, agent: State.agentID) }
    }

    public func reportFixedTask(
        _ scope: AgentTaskScope, input: AgentInput, result: ToolResult, status: AgentTaskSignal.Status? = nil
    ) async throws {
        let content = try AgentTaskContent(
            text: String(result.value.prefix(1024)).isEmpty ? "Completed" : String(result.value.prefix(1024)),
            stage: .completed)
        let signal = try content.signal(
            .result, scope: scope, status: status ?? (result.isError ? .failed : .succeeded))
        try await contextRepository.update {
            try $0.tasks.report(signal, agent: State.agentID)
            $0.state.taskViews?[scope.id]?.terminal = true
            $0.state.taskViews?[scope.id]?.stage = .completed
            $0.state.taskViews?[scope.id]?.text = content.text
        }
        let report = try await communicate(signal.message(), parent: input, to: scope.requester)
        guard report.delivered.contains(scope.requester), report.rejected.isEmpty else {
            throw CommunicationError.unavailableTarget
        }
    }

    private func modelCommunication(path: String, arguments: [String: String], input: AgentInput) async throws
        -> ToolResult
    {
        var validated = false
        do {
            let snapshot = try await contextRepository.snapshot()
            let scope = arguments["taskID"].flatMap(BusinessRecordID.parse).flatMap { snapshot.tasks.task($0)?.scope }
            var (action, signal) = try AgentCommunicationAdapter.action(
                path: path, arguments: arguments,
                sender: descriptor.id, input: input, policy: communicationPolicy, existing: scope)
            if signal.kind == .input, signal.scope.execution == .foreground,
                let view = snapshot.state.taskViews?[signal.scope.id], view.stage == .waitingUser
            {
                guard let captured = inputInteractions[input.id]?.first(where: { $0.scope.id == view.scope.id }),
                    captured.interactionID == view.interactionID, captured.artifactID == view.artifactID
                else { throw CommunicationError.scopeClosed }
                let content = try AgentTaskContent(
                    text: arguments["content"] ?? "", interactionID: captured.interactionID,
                    artifactID: captured.artifactID)
                signal = try content.signal(.input, scope: signal.scope)
                action = try CommunicationAction(message: signal.message(), target: signal.scope.executor)
            }
            try State.validateCommunication(signal, state: snapshot.state)
            validated = true
            let stableSignal = signal
            if stableSignal.kind == .request {
                try await contextRepository.update { context in
                    try context.tasks.register(stableSignal.scope)
                    var views = context.state.taskViews ?? [:]
                    guard views.values.filter({ !$0.terminal }).count < 32 else {
                        throw CommunicationError.capacityExceeded
                    }
                    if views.count == 256, let retired = views.first(where: { $0.value.terminal }) {
                        views[retired.key] = nil
                    }
                    views[stableSignal.scope.id] = AgentTaskView(
                        scope: stableSignal.scope, content: try AgentTaskContent.decode(stableSignal))
                    context.state.taskViews = views
                }
            } else if stableSignal.kind == .progress || stableSignal.kind == .result {
                let content = try AgentTaskContent.decode(stableSignal)
                try await contextRepository.update { context in
                    if stableSignal.kind == .result { try context.tasks.report(stableSignal, agent: State.agentID) }
                    var views = context.state.taskViews ?? [:]
                    views[stableSignal.scope.id] = AgentTaskView(
                        scope: stableSignal.scope, content: content, terminal: stableSignal.kind == .result)
                    context.state.taskViews = views
                }
            }
            let report = try await communicate(action.message, parent: input, to: action.target)
            let accepted = report.failure == nil && report.rejected.isEmpty && !report.delivered.isEmpty
            if stableSignal.kind == .input || stableSignal.kind == .cancel {
                try await contextRepository.update {
                    try $0.tasks.delivered(stableSignal.scope.id, kind: stableSignal.kind, accepted: accepted)
                }
            }
            if accepted && stableSignal.kind == .input {
                try await contextRepository.update { $0.state.taskViews?[stableSignal.scope.id]?.stage = .running }
                if foregroundInteraction == stableSignal.scope.id {
                    pendingInteractions.removeAll { $0 == stableSignal.scope.id }
                    foregroundInteraction = nil
                    try await activateNextInteraction(parent: input)
                }
            }
            if stableSignal.kind == .request {
                try await contextRepository.update { context in
                    try context.tasks.acknowledge(stableSignal.scope.id, accepted: accepted)
                    if !accepted { context.state.taskViews?[stableSignal.scope.id]?.terminal = true }
                }
            }
            return ToolResult(
                callID: action.id, value: String(decoding: try JSONEncoder().encode(report), as: UTF8.self),
                isError: !accepted, failureCode: accepted ? nil : "deliveryRejected", completion: .completed)
        } catch {
            if validated || error is CancellationError || Task.isCancelled { throw error }
            return ToolResult(
                callID: UUID().uuidString,
                value:
                    "Communication rejected: \(error). Valid kind values are request, input, progress, result, cancel. A new task uses kind=request, target and content without taskID. No task was accepted for this call.",
                isError: true, failureCode: "communicationRejected")
        }
    }

    private func receiveTask(_ signal: AgentTaskSignal, input: AgentInput) async throws {
        if signal.businessContract == "runtime.replyFinished" {
            guard State.tracksDelegatedReplies, input.metadata.origin == .runtime,
                signal.scope.requester == descriptor.id
            else { throw CommunicationError.unauthorized }
            if reportsReplyActivity,
                (try await contextRepository.snapshot()).state.taskViews?[signal.scope.id]?.stage == .waitingUser
            {
                replyTasks.remove(signal.scope.id)
                publishReplyActivity(for: input)
                drain()
            }
            return
        }
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        if usesSkills && signal.scope.execution == .background && (signal.kind == .request || signal.kind == .input) {
            throw CommunicationError.unsupportedContract
        }
        let content: AgentTaskContent
        if signal.kind == .cancel || signal.businessContract == "runtime.taskTermination" {
            content = try AgentTaskContent(text: "Task stopped", stage: signal.kind == .result ? .completed : .running)
        } else if signal.scope.execution == .background && signal.businessContract != AgentTaskContent.contract {
            guard signal.kind == .progress || signal.kind == .result else {
                throw CommunicationError.unsupportedContract
            }
            content = try AgentTaskContent(
                text: String(
                    (String(data: signal.data, encoding: .utf8) ?? "Opaque task evidence: \(signal.data.count) bytes")
                        .prefix(1024)),
                stage: signal.kind == .result ? .completed : .running)
        } else {
            content = try AgentTaskContent.decode(signal)
        }
        if signal.scope.executor == .writer, let event = content.writerEvent {
            try await receiveWriterEvent(signal, content: content, event: event, input: input)
            return
        }
        let prior = (try await contextRepository.snapshot()).state.taskViews?[signal.scope.id]
        if signal.kind == .input, signal.scope.execution == .foreground, prior?.stage == .waitingUser {
            guard content.interactionID == prior?.interactionID, content.artifactID == prior?.artifactID
            else { throw CommunicationError.scopeClosed }
        }
        try await contextRepository.recordSignal(
            input, disposition: .control, admissionSequence: (try await contextRepository.snapshot()).revision + 1,
            consumed: true, retainingLast: 4096
        ) { context in
            try context.tasks.accept(signal, input: input, agent: State.agentID)
            var views = context.state.taskViews ?? [:]
            views[signal.scope.id] = AgentTaskView(
                scope: signal.scope, content: content, terminal: signal.kind == .result)
            if signal.scope.execution == .background {
                views[signal.scope.id]?.goal = prior?.goal ?? signal.goal
                views[signal.scope.id]?.skills = prior?.skills ?? signal.requestedSkills
                views[signal.scope.id]?.createdAt = prior?.createdAt
            }
            context.state.taskViews = views
        }
        if signal.kind == .result, signal.scope.execution == .foreground,
            BusinessRecordID(rawValue: signal.scope.id)?.kind == .task
        {
            try await taskRecords?.endTask(
                signal.scope.id,
                status: signal.status == .succeeded ? "completed" : (signal.status?.rawValue ?? "failed"),
                failure: signal.status == .succeeded ? nil : content.text)
        }
        if signal.scope.execution == .background {
            if fullDuplex, signal.kind == .progress || signal.kind == .result {
                try await admitPeerText(
                    content.text, input: input)
            }
            return
        }
        if fullDuplex, signal.kind == .progress || signal.kind == .result {
            try await admitPeerText(
                content.text, input: input)
        }
        if reportsReplyActivity {
            if signal.kind == .result {
                replyTasks.remove(signal.scope.id)
            } else if signal.kind == .progress {
                replyTasks.insert(signal.scope.id)
            }
            publishReplyActivity(for: input)
        }
        defer { drain() }
        switch signal.kind {
        case .progress:
            if content.stage == .waitingUser {
                guard pendingInteractions.count < 32 else { throw CommunicationError.capacityExceeded }
                if !pendingInteractions.contains(signal.scope.id) { pendingInteractions.append(signal.scope.id) }
                try await activateNextInteraction(parent: input)
            }
        case .result:
            pendingInteractions.removeAll { $0 == signal.scope.id }
            if foregroundInteraction == signal.scope.id { foregroundInteraction = nil }
            try await activateNextInteraction(parent: input)
        case .cancel:
            let pending = queue.inputs.filter { $0.taskScope?.id == signal.scope.id }
            for value in pending {
                queue.remove(id: value.id)
                continuationRounds[value.id] = nil
                try await contextRepository.update {
                    if $0.work[value.id]?.state.terminal == false { try $0.transitionWork(value.id, to: .cancelled) }
                }
            }
            if activeInput?.taskScope?.id == signal.scope.id {
                worker?.cancel()
                await worker?.value
            }
            try await reportFixedTask(
                signal.scope, input: input,
                result: ToolResult(callID: input.id, value: "Task cancelled", isError: true), status: .cancelled)
        case .request, .input:
            if fullDuplex {
                try await admitPeerText(content.text, input: input, scope: signal.scope)
                return
            }
            let decision = AgentInput(
                id: input.id, sessionID: input.sessionID, payload: .text(content.text),
                metadata: input.metadata, turn: input.turn, taskScope: signal.scope)
            if signal.kind == .input, content.stage == .waitingUser {
                immediateInputs.insert(input.id)
            }
            try await receive(decision)
        }
    }

    private func receiveWriterEvent(
        _ signal: AgentTaskSignal, content: AgentTaskContent, event: WriterDelegationEvent, input: AgentInput
    ) async throws {
        try event.validate()
        guard input.metadata.origin == .agent, input.metadata.source == "writer", input.metadata.incarnation != nil,
            signal.scope.requester == descriptor.id, signal.scope.execution == .background
        else { throw CommunicationError.unauthorized }
        guard signal.kind == .progress,
            [.started, .draftUpdated, .recovering, .userInput].contains(event.kind),
            event.kind == .userInput
                ? content.stage == .waitingUser && content.interactionID != nil
                : content.stage == .running && content.interactionID == nil
        else { throw CommunicationError.invalidPayload }
        let snapshot = try await contextRepository.snapshot()
        guard let prior = snapshot.state.taskViews?[signal.scope.id], prior.scope == signal.scope else {
            throw CommunicationError.scopeClosed
        }
        if prior.terminal || (prior.stage == .waitingUser && event.kind.isMilestone)
            || prior.writerEvent?.eventID == event.eventID
            || event.sequence <= (prior.writerEvent?.sequence ?? 0)
        {
            return
        }
        try await contextRepository.recordSignal(
            input, disposition: .control, admissionSequence: snapshot.revision + 1, consumed: true,
            retainingLast: 4096
        ) { context in
            guard let prior = context.state.taskViews?[signal.scope.id], prior.scope == signal.scope else {
                throw CommunicationError.scopeClosed
            }
            guard event.delegateID == nil || event.delegateID == signal.scope.id
            else { throw CommunicationError.invalidPayload }
            if prior.terminal || (prior.stage == .waitingUser && event.kind.isMilestone)
                || prior.writerEvent?.eventID == event.eventID
                || event.sequence <= (prior.writerEvent?.sequence ?? 0)
            {
                return
            }
            try context.tasks.accept(signal, input: input, agent: State.agentID)
            var view = AgentTaskView(scope: signal.scope, content: content)
            view.goal = prior.goal
            view.originDialog = prior.originDialog
            view.createdAt = prior.createdAt
            view.retainWriterFacts(from: prior)
            context.state.taskViews?[signal.scope.id] = view
        }
        if let view = (try await contextRepository.snapshot()).state.taskViews?[signal.scope.id],
            view.writerEvent?.eventID == event.eventID
        {
            try await enqueueWriterNotice(view, input: input)
        }
    }

    /// Canonical Writer completion, not a user-notification receipt, ends task occupancy.
    private func reconcileWriterExecutions() async throws {
        guard taskRecords != nil else { throw RecordStorageError.missingRecord }
        let snapshot = try await contextRepository.snapshot()
        for view in (snapshot.state.taskViews ?? [:]).values
        where view.scope.executor == .writer {
            let active =
                snapshot.tasks.task(view.scope.id).map {
                    ![AgentTaskRegistry.State.succeeded, .failed, .cancelled, .interrupted].contains($0.state)
                } ?? false
            guard !view.terminal || active else { continue }
            guard
                let message = try await requireCommunications().agentReply(
                    to: view.scope.id, contract: "writer.completion")
            else { continue }
            let ended = try JSONDecoder().decode(WriterDelegationCompletion.self, from: message.payload).signal
            guard message.sender == "writer", message.receiver == descriptor.id.rawValue, ended.scope == view.scope
            else { throw CommunicationError.invalidPayload }
            try await contextRepository.update { context in
                if let state = context.tasks.task(view.scope.id)?.state,
                    ![.succeeded, .failed, .cancelled, .interrupted].contains(state)
                {
                    try context.tasks.report(ended, agent: .writer)
                }
                guard var value = context.state.taskViews?[view.scope.id], !value.terminal else { return }
                value.terminal = true
                value.stage = .completed
                value.text = try AgentTaskContent.decode(ended).text
                context.state.taskViews?[view.scope.id] = value
                try context.append(
                    .init(taskID: view.scope.id, kind: "writer.execution.closed", data: JSONEncoder().encode(ended)))
            }
        }
    }
    private func receiveWriterCompletion(_ completion: WriterDelegationCompletion, input: AgentInput) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        try completion.validate()
        guard State.agentID == .assistant, input.metadata.origin == .agent, input.metadata.source == "writer",
            input.metadata.incarnation != nil, taskRecords != nil
        else { throw CommunicationError.unauthorized }
        let signal = completion.signal
        guard input.sessionID == signal.scope.sessionID else { throw CommunicationError.unauthorized }
        let content = try AgentTaskContent.decode(signal)
        guard let event = content.writerEvent else { throw CommunicationError.invalidPayload }
        guard let stored = try await requireCommunications().agentMessage(event.eventID),
            stored.sender == "writer", stored.receiver == descriptor.id.rawValue,
            stored.contract == "writer.completion", stored.correlationID == signal.scope.id,
            try JSONDecoder().decode(WriterDelegationCompletion.self, from: stored.payload) == completion
        else { throw CommunicationError.invalidPayload }
        let snapshot = try await contextRepository.snapshot()
        if snapshot.state.taskViews?[signal.scope.id]?.writerEvent?.eventID == event.eventID {
            try await requireCommunications().receiveAgentMessage(
                event.eventID, receiver: descriptor.id.rawValue, consumed: true)
            return
        }
        let evidence = AgentInput(
            id: event.eventID, sessionID: input.sessionID, payload: input.payload, metadata: input.metadata)
        try await contextRepository.recordSignal(
            evidence, disposition: .control, admissionSequence: snapshot.revision + 1,
            consumed: true, retainingLast: 4096
        ) { context in
            if context.state.taskViews?.count == 256,
                context.state.taskViews?[signal.scope.id] == nil,
                let retired = context.state.taskViews?.first(where: { $0.value.terminal })?.key
            {
                context.state.taskViews?[retired] = nil
            }
            guard (context.state.taskViews?.count ?? 0) < 256 || context.state.taskViews?[signal.scope.id] != nil else {
                throw CommunicationError.capacityExceeded
            }
            let prior = context.state.taskViews?[signal.scope.id]
            var view = AgentTaskView(scope: signal.scope, content: content, terminal: true)
            view.goal = prior?.goal
            view.originDialog = prior?.originDialog
            view.createdAt = prior?.createdAt ?? Date()
            view.retainWriterFacts(from: prior)
            context.state.taskViews = context.state.taskViews ?? [:]
            context.state.taskViews?[signal.scope.id] = view
            if let state = context.tasks.task(signal.scope.id)?.state,
                ![.succeeded, .failed, .cancelled, .interrupted].contains(state)
            {
                try context.tasks.report(signal, agent: .writer)
            }
        }
        if let view = (try await contextRepository.snapshot()).state.taskViews?[signal.scope.id] {
            try await enqueueWriterNotice(view, input: input)
        }
        try await requireCommunications().receiveAgentMessage(
            event.eventID, receiver: descriptor.id.rawValue, consumed: true)
    }

    private static func writerFacts(
        from views: [String: AgentTaskView], dialog: String, budget: Int, templates: PromptTemplates
    ) throws -> String {
        let recent = views.values.filter { $0.originDialog == dialog && $0.writerFacts?.isEmpty == false }
            .sorted {
                ($0.writerFacts?.last?.receivedAt ?? .distantPast) > ($1.writerFacts?.last?.receivedAt ?? .distantPast)
            }
            .prefix(2)
        guard !recent.isEmpty else { return "" }
        let heading = try templates.render("writerEventsHeading")
        var block = heading
        for view in recent {
            var entries = view.writerFacts?.map { ["event": $0.kind.rawValue, "text": $0.text] } ?? []
            let fact = [
                "workspaceID": view.writerEvent?.workspaceID ?? "",
                "goal": String((view.goal ?? view.writerEvent?.goal ?? "").prefix(120)),
            ]
            let header = String(decoding: try JSONEncoder().encode(fact), as: UTF8.self)
            while !entries.isEmpty {
                let events = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
                let line = try templates.render("writerEvent", variables: ["workspace": header, "events": events])
                if block.utf8.count + line.utf8.count <= budget {
                    block += line
                    break
                }
                entries.removeFirst()
            }
        }
        return block == heading ? "" : block
    }

    /// Only called after the owning task's identity and sequence have been validated.
    private func admitPeerText(_ text: String, input: AgentInput, scope: AgentTaskScope? = nil) async throws {
        let candidate = AgentInput(
            id: input.id + ".semantic", sessionID: input.sessionID,
            payload: .text(text), metadata: input.metadata, turn: input.turn, taskScope: scope)
        let semantic = try makeSemanticMessage(
            input: candidate, role: .agent, channel: "agent." + input.metadata.source, content: text)
        try await receiveSignal(candidate, semantic: semantic)
    }

    private func enqueueWriterNotice(_ view: AgentTaskView, input: AgentInput) async throws {
        if fullDuplex {
            guard view.originDialog == (try await contextRepository.snapshot()).state.history.current.id else { return }
            try await admitPeerText(
                view.text, input: input)
            return
        }
        guard reportsReplyActivity, let event = view.writerEvent, let originDialog = view.originDialog else { return }
        if view.terminal {
            writerNotices.removeAll {
                $0.scopeID == view.scope.id && ($0.kind.isMilestone || $0.kind == .userInput)
            }
        }
        if writerNotices.count == 8 {
            let index = writerNotices.firstIndex(where: { $0.kind.isMilestone }) ?? writerNotices.startIndex
            writerNotices.remove(at: index)
            Logger(subsystem: "dev.mobileharness", category: "WriterNotice").warning(
                "Assistant Writer notice queue full")
        }
        let text = view.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let summary = text.count == 2 && text[0].hasPrefix("工作区 workspace_") ? text[1] : view.text[...]
        let anchor = AgentInput(
            id: event.eventID, sessionID: input.sessionID, payload: input.payload, metadata: input.metadata)
        writerNotices.append(
            WriterNotice(
                input: anchor, scopeID: view.scope.id, originDialog: originDialog, kind: event.kind,
                interactionID: view.interactionID, text: "Writer。 " + String(summary.prefix(180))))
        drain()
    }

    private func playWriterNotice(_ notice: WriterNotice) async {
        let input = notice.input
        defer {
            activeWriterNoticeID = nil
            activeInput = nil
            worker = nil
            finishHostCancellation(input)
            drain()
        }
        do {
            let snapshot = try await contextRepository.snapshot()
            try Task.checkCancellation()
            guard lifecycle == .running, snapshot.state.history.current.id == notice.originDialog else { return }
            if notice.kind == .userInput || notice.kind.isMilestone {
                let view = snapshot.state.taskViews?[notice.scopeID]
                guard view?.terminal == false else { return }
                if notice.kind == .userInput, view?.interactionID != notice.interactionID { return }
            }
            replyInputs.insert(input.id)
            publishReplyActivity(for: input)
            try await emitPlayback(notice.text, for: input)
            emit(.control("agent.finished"), for: input)
        } catch is CancellationError {
            if hostCancelledInput?.id != input.id { emit(.control("agent.cancelled"), for: input) }
        } catch {
            emitFailure(error, for: input)
        }
    }

    private func activateNextInteraction(parent: AgentInput) async throws {
        guard foregroundInteraction == nil, let id = pendingInteractions.first,
            let view = (try await contextRepository.snapshot()).state.taskViews?[id], !view.terminal
        else { return }
        foregroundInteraction = id
        let content = try AgentTaskContent(
            text: view.text, stage: .waitingUser,
            interactionID: view.interactionID, artifactID: view.artifactID)
        let report = try await communicate(
            content.signal(.input, scope: view.scope).message(), parent: parent, to: view.scope.executor)
        guard report.rejected.isEmpty, report.delivered.contains(view.scope.executor) else {
            foregroundInteraction = nil
            throw CommunicationError.unavailableTarget
        }
    }

    private func completeTaskDecision(_ input: AgentInput) async throws {
        guard let scope = input.taskScope else { return }
        let snapshot = try await contextRepository.snapshot()
        if snapshot.state.taskViews?[scope.id]?.stage == .waitingUser
            || snapshot.state.taskViews?[scope.id]?.terminal == true
        {
            return
        }
        let turn = snapshot.state.history.current.turns.first { $0.id == input.id }
        try await reportFixedTask(
            scope, input: input,
            result: ToolResult(
                callID: input.id,
                value: String((turn?.raw ?? "Task completed").prefix(1024))))
    }

    private func requireTaskSignal(_ input: AgentInput) throws -> AgentTaskSignal {
        guard case .observation(let message) = input.payload,
            let signal = message.content(as: AgentTaskSignal.self)
        else { throw CommunicationError.invalidPayload }
        return signal
    }

    private func releaseDelegations(parent: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        for view in (snapshot.state.taskViews ?? [:]).values
        where view.scope.parentID == parent.id && !view.terminal
            && State.commitDependentTargets.contains(view.scope.executor)
            && !snapshot.records.contains(where: { $0.taskID == view.scope.id && $0.kind == "delegation.released" })
        {
            let signal = try AgentTaskSignal(
                kind: .input, scope: view.scope,
                businessContract: "agent.parentCommitted", data: Data())
            let report = try await communicate(signal.message(), parent: parent, to: view.scope.executor)
            guard report.delivered.contains(view.scope.executor), report.rejected.isEmpty else {
                throw CommunicationError.unavailableTarget
            }
            try await contextRepository.update {
                try $0.append(.init(taskID: view.scope.id, kind: "delegation.released"))
            }
        }
    }

    private func clearWriterInteraction(_ view: AgentTaskView) async throws {
        try await contextRepository.update { context in
            guard let current = context.state.taskViews?[view.scope.id], !current.terminal,
                current.interactionID == view.interactionID
            else { return }
            context.state.taskViews?[view.scope.id]?.interactionID = nil
            context.state.taskViews?[view.scope.id]?.stage = .running
        }
    }

    private func forwardDirectedInput(_ intent: AgentTaskInputIntent, input: AgentInput) async throws {
        guard lifecycle == .running, input.metadata.origin == .local, input.metadata.source == "user",
            input.metadata.incarnation == nil,
            let view = (try await contextRepository.snapshot()).state.taskViews?[intent.taskID],
            !view.terminal, view.scope.sessionID == input.sessionID, view.stage == .waitingUser,
            view.interactionID == intent.interactionID, view.artifactID == intent.artifactID,
            routingWorkers.count < 32
        else { throw CommunicationError.scopeClosed }
        let content = try AgentTaskContent(
            text: intent.text, interactionID: intent.interactionID, artifactID: intent.artifactID)
        let signal = try content.signal(.input, scope: view.scope)
        try await contextRepository.recordSignal(
            input, disposition: .control,
            admissionSequence: (try await contextRepository.snapshot()).revision + 1, consumed: true,
            retainingLast: 4096)
        routingSessions[input.id] = input.sessionID
        routingWorkers[input.id] = Task {
            defer {
                routingWorkers[input.id] = nil
                routingSessions[input.id] = nil
            }
            do {
                let report = try await communicate(signal.message(), parent: input, to: view.scope.executor)
                guard report.delivered.contains(view.scope.executor), report.rejected.isEmpty else {
                    throw CommunicationError.unavailableTarget
                }
                if view.scope.executor == .writer { try await clearWriterInteraction(view) }
                if foregroundInteraction == view.scope.id {
                    pendingInteractions.removeAll { $0 == view.scope.id }
                    foregroundInteraction = nil
                    try await activateNextInteraction(parent: input)
                }
            } catch { emit(.control("agent.inputRejected: \(error)"), for: input) }
        }
    }

    // MARK: - Context

    private func prepareSignal(_ input: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try State.preprocess(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if usesSkills, disposition != .feedback { try stateContext?.open(session: input.sessionID) }
        let consumed: Bool
        if case .text = input.payload {
            consumed = false
        } else if case .transcript(_, final: true)? = input.payload.perception {
            consumed = false
        } else {
            consumed = disposition == .control
        }
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: consumed, retainingLast: 4096
        ) { context in
            if disposition != .feedback { context.state.admissionSequence += 1 }
            if var skills = context.state.skillState {
                if case .speechPhase(.speaking)? = input.payload.perception, let turn = input.turn {
                    guard skills.recognitionBindings.count < 32 || skills.recognitionBindings[turn.id] != nil else {
                        throw CommunicationError.capacityExceeded
                    }
                    // A default-mode onset also gets a marker so a later task cannot capture it.
                    skills.recognitionBindings[turn.id] =
                        skills.activeTaskID.map(RecognitionBinding.task) ?? .conversation
                } else if case .speechPhase(.empty)? = input.payload.perception, let turn = input.turn {
                    skills.recognitionBindings[turn.id] = nil
                } else if case .text = input.payload {
                    try skills.bind(input.id, task: skills.activeTaskID)
                } else if case .transcript(_, final: true)? = input.payload.perception {
                    let captured = input.turn.flatMap { skills.recognitionBindings.removeValue(forKey: $0.id) }
                    guard captured != nil || skills.activeTaskID == nil else { throw CommunicationError.scopeClosed }
                    let taskID: String?
                    switch captured {
                    case .conversation: taskID = nil
                    case .task(let id): taskID = id
                    case nil: taskID = skills.activeTaskID
                    }
                    try skills.bind(input.id, task: taskID)
                }
                context.state.skillState = skills
            }
            if case .text = input.payload {
                try context.beginWork(input.id, sessionID: input.sessionID)
            } else if case .transcript(_, final: true)? = input.payload.perception {
                try context.beginWork(input.id, sessionID: input.sessionID)
            }
        }
        if usesSkills,
            input.payload.kind == .text
                || {
                    if case .transcript(_, final: true)? = input.payload.perception { return true }
                    return false
                }(), let skills = try await contextRepository.snapshot().state.skillState
        {
            skillContinuation.yield(skills)
        }
    }

    // MARK: - Observability

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: queue.count + decisionPending.count, processedInputs: processed)
    }

    /// Passive State reflection, independent of persistence initialization.
    public func residentContext() async -> AgentContext<State>? {
        await contextRepository.residentSnapshot()
    }

    public func contextSnapshot() async throws -> AgentContext<State> {
        try await contextRepository.snapshot()
    }
    public func effectiveCapabilities(for id: String) throws -> CapabilityRegistry? {
        guard usesSkills else { return nil }
        if let parked = pendingRounds[id] {
            guard !parked.cancelled, let catalog = parked.catalog else { throw CommunicationError.scopeClosed }
            return catalog
        }
        guard id == roundID, let requestCatalog else { throw CommunicationError.scopeClosed }
        return requestCatalog
    }
    public func controlTask(
        _ operation: String, arguments: [String: String], source: String, sessionID: String,
        inputID: String, decisionID: String?,
        beforeSuperseding: @Sendable () async throws -> Void = {}
    ) async throws -> ActionCompletion {
        guard usesSkills, source == descriptor.id.rawValue, lifecycle == .running else {
            throw CommunicationError.unauthorized
        }
        let fixed = decisionID == nil
        let parked = decisionID.flatMap { pendingRounds[$0] }
        let controlInput = parked?.input ?? activeInput
        if let parked {
            guard !parked.cancelled,
                parked.requestTaskID == (try await contextRepository.snapshot()).state.skillState?.activeTaskID
            else { throw CommunicationError.scopeClosed }
        }
        if fixed {
            let idleForControl = (activeInput == nil && worker == nil) || activeWriterNoticeID != nil
            guard idleForControl, queue.count == 0, admitting == 0 else {
                throw AssistantHistoryError.busy
            }
        } else {
            guard controlInput?.id == inputID, controlInput?.sessionID == sessionID,
                decisionID == roundID || parked != nil
            else {
                throw CommunicationError.unauthorized
            }
        }
        if ["task.send", "task.cancel"].contains(operation), let target = arguments["agent_id"] {
            try await reconcileWriterExecutions()
            let cancelling = operation == "task.cancel"
            let allowed: Set<String> = cancelling ? ["agent_id", "reason"] : ["agent_id", "text"]
            let matches =
                try await contextRepository.snapshot().state.taskViews?.values.filter {
                    !$0.terminal && $0.scope.executor.rawValue == target && $0.scope.sessionID == sessionID
                } ?? []
            guard matches.count == 1, Set(arguments.keys).isSubset(of: allowed),
                let text = arguments[cancelling ? "reason" : "text"],
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_384,
                let view = matches.first, view.scope.sessionID == sessionID, view.scope.execution == .background,
                cancelling || view.scope.executor == .writer
            else { throw CommunicationError.invalidPayload }
            if !cancelling, let interaction = view.interactionID {
                guard let captured = inputInteractions[inputID]?.first(where: { $0.scope.id == view.scope.id }),
                    captured.interactionID == interaction
                else { throw CommunicationError.scopeClosed }
            }
            let parent =
                (fixed ? nil : controlInput) ?? AgentInput(id: inputID, sessionID: sessionID, payload: .text(text))
            let signal = try AgentTaskContent(text: text, interactionID: cancelling ? nil : view.interactionID).signal(
                cancelling ? .cancel : .input, scope: view.scope)
            let report = try await communicate(signal.message(), parent: parent, to: view.scope.executor)
            guard report.failure == nil, report.rejected.isEmpty, report.delivered.contains(view.scope.executor) else {
                throw CommunicationError.unavailableTarget
            }
            if !cancelling { try await clearWriterInteraction(view) }
            if view.scope.executor == .writer { return .completed }
            return .value("Cancellation delivered; await executor terminal confirmation. Foreground unchanged.")
        }
        if operation == "task.delegate" {
            guard !fixed, Set(arguments.keys) == ["agent_id", "description"],
                let target = arguments["agent_id"],
                AgentTaskDelegation.permits(
                    target: AgentID(rawValue: target), requester: descriptor.id, communication: communicationPolicy),
                let parent = controlInput,
                let goal = arguments["description"], !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                goal.utf8.count <= 1024, !goal.contains("\n"), !goal.contains("\r")
            else { throw CommunicationError.invalidPayload }
            guard !delegationInProgress, delegationInputID != parent.id else {
                throw CapabilityError.unavailable("Delegation already attempted for this input")
            }
            delegationInProgress = true
            defer { delegationInProgress = false }
            try await reconcileWriterExecutions()
            guard
                try await contextRepository.snapshot().state.taskViews?.values.contains(where: {
                    $0.scope.executor == .writer && !$0.terminal
                }) != true
            else { throw CapabilityError.unavailable("Writer busy; send input or cancel and await cleanup") }
            let original: String
            switch parent.payload {
            case .text(let text): original = text
            case .observation(let message):
                if case .transcript(let text, _) = message.perception {
                    original = text
                } else {
                    throw CommunicationError.invalidPayload
                }
            default: throw CommunicationError.invalidPayload
            }
            delegationInputID = parent.id
            try await delegate(goal: goal, request: original, to: AgentID(rawValue: target), parent: parent)
            return .completed
        }
        if operation == "task.send" {
            guard Set(arguments.keys) == ["text"], let text = arguments["text"],
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_384,
                try await contextRepository.snapshot().state.skillState?.activeTaskID != nil
            else { throw CommunicationError.invalidPayload }
            // The Action result is persisted as input evidence for the next ReACT round.
            return .value("Foreground task input: " + text)
        }
        try stateContext?.open(session: sessionID)
        guard !taskControlInProgress else { throw AssistantHistoryError.busy }
        taskControlInProgress = true
        defer { taskControlInProgress = false }
        if fullDuplex, operation == "task.end", let decisionID {
            return try await completeForegroundTask(arguments: arguments, inputID: inputID, requestID: decisionID)
        }
        let fixedCapabilities = descriptor.capabilities
        var newTaskID: String?
        if operation == "task.start" {
            var preview = try await contextRepository.snapshot().state.skillState
            guard preview != nil else { throw CommunicationError.invalidPayload }
            let previous = preview?.activeTaskID
            if previous != nil { try preview?.settleTask(failed: false, fixed: fixedCapabilities, cancelled: true) }
            // Validate all Skill/state constraints without changing the authoritative context.
            _ = try preview?.control(
                operation, arguments: arguments, inputID: inputID,
                fixed: fixedCapabilities, sessionID: sessionID, taskID: "task_1")
            guard let taskRecords else { throw RecordStorageError.missingRecord }
            if let previous {
                try await beforeSuperseding()
                try await conversations.checkpoint(inputID: inputID)
                try await taskRecords.endTask(previous, status: "cancelled", failure: "superseded")
                try await contextRepository.update {
                    try $0.state.skillState?.settleTask(failed: false, fixed: fixedCapabilities, cancelled: true)
                    $0.state.reconcileTaskCompressions()
                }
            }
            let dialog = try await conversations.readCurrent().current.id
            newTaskID = try await taskRecords.createTask(
                dialog: BusinessRecordID(rawValue: dialog)?.kind == .dialog ? dialog : nil,
                agent: descriptor.id.rawValue, goal: arguments["description"] ?? "")
        }
        let committedTaskID = newTaskID
        let result: String
        do {
            result = try await contextRepository.transaction { context in
                guard var skills = context.state.skillState else { throw CommunicationError.invalidPayload }
                if fixed && operation == "loadSkills" && skills.activeTaskID == nil {
                    throw CommunicationError.scopeClosed
                }
                var result = try skills.control(
                    operation, arguments: arguments, inputID: inputID, fixed: fixedCapabilities, sessionID: sessionID,
                    taskID: committedTaskID)
                if fixed && ["task.end", "task.cancel"].contains(operation) {
                    try skills.settleTask(failed: false, fixed: fixedCapabilities)
                    result =
                        "Mode=\(skills.mode); task=none; Skills=\(skills.loaded.joined(separator: ",")); transition committed."
                }
                if operation == "task.start", let decisionID, let taskID = skills.activeTaskID {
                    try context.state.history.assignHistoryTask(taskID, inputID: inputID, requestID: decisionID)
                }
                context.state.skillState = skills
                context.state.reconcileTaskCompressions()
                return result
            }
        } catch {
            if let committedTaskID {
                try await taskRecords?.endTask(committedTaskID, status: "failed", failure: String(describing: error))
            }
            throw error
        }
        if let committed = try await contextRepository.snapshot().state.skillState {
            if let task = committed.tasks.last,
                ["completed", "cancelled", "failed", "interrupted"].contains(task.status)
            {
                try await taskRecords?.endTask(
                    task.id, status: task.status, failure: task.failure, finishedAt: task.updatedAt ?? Date())
            }
            skillContinuation.yield(committed)
        }
        try await conversations.checkpoint(inputID: inputID)
        return .value(result)
    }

    private func completeForegroundTask(arguments: [String: String], inputID: String, requestID: String) async throws
        -> ActionCompletion
    {
        let fixed = descriptor.capabilities
        guard var skills = try await contextRepository.snapshot().state.skillState,
            let task = skills.tasks.first(where: { $0.id == skills.activeTaskID }),
            skills.taskID(for: inputID) == task.id, let summary = arguments["summary"]
        else { throw CommunicationError.scopeClosed }
        _ = try skills.control("task.end", arguments: arguments, inputID: inputID, fixed: fixed)
        let finishedAt = Date()
        try await conversations.completeForegroundTask(
            task.id, goal: task.goal, summary: summary, finishedAt: finishedAt, inputID: inputID, requestID: requestID
        ) { [contextRepository] archive, persist in
            try await contextRepository.transaction(beforePublishing: persist) { context in
                guard var skills = context.state.skillState, skills.activeTaskID == task.id,
                    context.state.history.revision == archive.revision - 1
                else { throw CommunicationError.scopeClosed }
                _ = try skills.control("task.end", arguments: arguments, inputID: inputID, fixed: fixed)
                try skills.settleTask(failed: false, fixed: fixed, finishedAt: finishedAt)
                context.state.skillState = skills
                context.state.history = archive
            }
        }
        if let skills = try await contextRepository.snapshot().state.skillState { skillContinuation.yield(skills) }
        guard arguments["continueDecision"] == "true" else { return .completed }
        let receipt = ["operation": "task.end", "status": "completed", "taskID": task.id]
        return .value(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))
    }

    private func delegate(goal: String, request: String, to target: AgentID, parent: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        guard taskRecords != nil else { throw RecordStorageError.missingRecord }
        let delegateID = UUID().uuidString
        let signal = try AgentTaskSignal(
            kind: .request,
            scope: AgentTaskScope(
                id: delegateID, requester: descriptor.id, executor: target,
                sessionID: parent.sessionID, execution: .background),
            data: JSONEncoder().encode(["request": request]), goal: goal)
        try await requireCommunications().enqueueAgentMessage(
            .init(
                id: delegateID, sender: descriptor.id.rawValue, receiver: target.rawValue,
                contract: signal.contract, payload: try JSONEncoder().encode(signal), correlationID: delegateID,
                senderContext: snapshot.state.history.current.id, dedupeKey: delegateID))
        do {
            try await contextRepository.update {
                try $0.tasks.register(signal.scope)
                var views = $0.state.taskViews ?? [:]
                if views.count == 256, let retired = views.first(where: { $0.value.terminal }) {
                    views[retired.key] = nil
                }
                guard views.count < 256 else { throw CommunicationError.capacityExceeded }
                views[signal.scope.id] = AgentTaskView(
                    scope: signal.scope, content: try AgentTaskContent(text: goal))
                views[signal.scope.id]?.originDialog = snapshot.state.history.current.id
                views[signal.scope.id]?.goal = goal
                views[signal.scope.id]?.createdAt = Date()
                $0.state.taskViews = views
            }
            let report = try await communicate(signal.message(), parent: parent, to: target)
            let accepted = report.failure == nil && report.rejected.isEmpty && report.delivered.contains(target)
            try await contextRepository.update {
                try $0.tasks.acknowledge(signal.scope.id, accepted: accepted)
                if !accepted { $0.state.taskViews?[signal.scope.id]?.terminal = true }
            }
            guard accepted else { throw CommunicationError.unavailableTarget }
        } catch {
            var cleanup: [any Error] = []
            do {
                try await contextRepository.update {
                    if $0.tasks.task(signal.scope.id) != nil {
                        try $0.tasks.acknowledge(signal.scope.id, accepted: false)
                    }
                    if $0.tasks.task(signal.scope.id)?.state == .failed {
                        $0.state.taskViews?[signal.scope.id]?.terminal = true
                        $0.state.taskViews?[signal.scope.id]?.stage = .completed
                        $0.state.taskViews?[signal.scope.id]?.text = String(describing: error)
                    }
                }
            } catch { cleanup.append(error) }
            do {
                try await requireCommunications().failAgentMessage(delegateID, failure: String(describing: error))
            } catch { cleanup.append(error) }
            if !cleanup.isEmpty {
                throw AgentFailure(
                    component: "assistant", operation: "task.delegate", underlying: error, cleanupErrors: cleanup)
            }
            throw error
        }
    }

    private func beginHistoryRequest(input: AgentInput, text: String, messages: [ChatMessage]) async throws
        -> AssistantRecord
    {
        let name = try await modelName()
        if State.agentID == .assistant { try await inputAdmission.acquire() }
        defer { if State.agentID == .assistant { inputAdmission.release() } }
        let history = try await conversations.readCurrent()
        if fullDuplex, let prepared = history.current.turns.first(where: { $0.id == input.id }),
            !prepared.awaitingModel, (prepared.modelRequests ?? []).allSatisfy({ $0.awaitingDispatch == true })
        {
            return prepared
        }
        return try await conversations.begin(
            id: input.id, user: Self.inputText(input) ?? text, request: AgentChatContextBuilder.project(messages),
            expecting: history.token, model: name)
    }

    private func finishLocalDecision(
        input: AgentInput, failed: Bool, failure: String? = nil, cancelled: Bool = false,
        taskBoundaryOnly: Bool = false
    ) async throws {
        guard usesSkills else { return }
        let fixedCapabilities = descriptor.capabilities
        let retainsConversation =
            cancelled
            && (lifecycle == .paused
                || (hostCancellationSession == input.sessionID && !hostCancellationClosesSession))
        try await contextRepository.update {
            guard let skills = $0.state.skillState,
                skills.activeTaskID == nil || skills.taskID(for: input.id) == skills.activeTaskID
            else {
                $0.state.skillState?.discardDecision(input.id)
                return
            }
            if retainsConversation {
                try $0.state.skillState?.interruptSession(
                    input.sessionID, inputs: [input.id], fixed: fixedCapabilities)
            } else if taskBoundaryOnly {
                try $0.state.skillState?.settleTask(
                    failed: failed, fixed: fixedCapabilities, failure: failure, cancelled: cancelled)
            } else {
                try $0.state.skillState?.decisionCompleted(
                    failed: failed, fixed: fixedCapabilities, inputID: input.id, failure: failure, cancelled: cancelled)
            }
            $0.state.reconcileTaskCompressions()
        }
        if let skills = try await contextRepository.snapshot().state.skillState {
            for task in skills.tasks
            where task.inputIDs.contains(input.id)
                && ["completed", "cancelled", "failed", "interrupted"].contains(task.status)
            {
                try await taskRecords?.endTask(
                    task.id, status: task.status, failure: task.failure, finishedAt: task.updatedAt ?? Date())
            }
            skillContinuation.yield(skills)
        }
    }
    private func decisionMetadata(skills: AgentTaskSkillState?, states: [String]? = nil)
        throws
        -> AssistantDecisionMetadata?
    {
        guard let skills else { return nil }
        let registry = requestCatalog ?? modelCapabilities
        let catalog: [String: Any] = [
            "actions": registry.actions.map {
                [
                    "path": $0.path.description, "alias": $0.alias, "channel": $0.defaultChannel,
                    "required": $0.requiredParameters.sorted(), "optional": $0.optionalParameters.sorted(),
                ] as [String: Any]
            },
            "tools": try registry.tools.map {
                [
                    "path": $0.path, "alias": $0.alias,
                    "required": $0.requiredParameters.sorted(), "optional": $0.optionalParameters.sorted(),
                    "definitionJSON": try $0.definition.map {
                        String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
                    } ?? "",
                ] as [String: Any]
            },
        ]
        var metadata = AssistantDecisionMetadata(
            taskID: skills.activeTaskID,
            mode: skills.mode,
            skills: try Dictionary(
                uniqueKeysWithValues: skills.loaded.map { ($0, try AgentConfigurations.skill($0).revision) }),
            catalogJSON: String(
                decoding: try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]), as: UTF8.self),
            taskGoal: skills.tasks.first(where: { $0.id == skills.activeTaskID })?.goal,
            execution: skills.activeTaskID == nil ? nil : "foreground")
        metadata.states = states
        return metadata
    }
    public func actionResults() -> [ActionResult] { resultInbox.results }
}
