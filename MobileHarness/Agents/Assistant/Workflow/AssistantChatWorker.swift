import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import Synchronization
import UI

struct AssistantChatRoundFailure: Error, CustomStringConvertible {
    let cause: any Error
    let cleanup: String
    var description: String {
        let detail = (cause as? any ChatFailureProviding)?.chatFailure.description ?? String(describing: cause)
        return "\(detail); round closure: \(cleanup)"
    }
}

/// Model-backed assistant; concrete model selection belongs exclusively to the composition root.
public actor AssistantChatWorker<State: AssistantChatState>: Agent {

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    public nonisolated let skillUpdates: AsyncStream<AgentTaskSkillState>
    let skillContinuation: AsyncStream<AgentTaskSkillState>.Continuation

    private(set) var speechOutput: (any AssistantSpeechProducing)?
    public func bindSpeechOutput(_ value: any AssistantSpeechProducing) throws {
        guard speechOutput == nil, worker == nil, lifecycle != .stopped else { throw HarnessError.invalidTransition }
        speechOutput = value
    }

    let taskRecords: (any AssistantTaskRepository)?
    let communications: (any AgentMessageRepository)?
    func requireCommunications() throws -> any AgentMessageRepository {
        guard let communications else { throw RecordStorageError.notReady }
        return communications
    }
    var taskControlInProgress = false
    let inputAdmission = AgentAdmissionGate(capacity: 32)
    let contextRepository: AgentContextRepository<State>
    let contextBuilder = AssistantChatRequestBuilder<State>()

    var resultInbox = ActionResultInbox()
    let continuation: AsyncStream<OutputEnvelope>.Continuation
    var messaging: AgentMessaging?
    struct TrackedTask {
        let token: UUID
        let producer: AgentID
        let sessionID: String
        var originDialog: String?
        var dynamicSubscription: AgentEventSubscription?
    }
    /// In-memory only: reports that arrive while untracked, including after a restart, are missed.
    var trackedTasks: [String: TrackedTask] = [:]
    public private(set) var messageRecordFailure: String?
    public var trackedTaskCount: Int { trackedTasks.count }
    public func bindMessaging(_ messaging: AgentMessaging) async throws {
        self.messaging = messaging
    }
    @discardableResult func trackTask(reference: String, producer: AgentID, sessionID: String) async throws
        -> Bool
    {
        if let existing = trackedTasks[reference] {
            guard existing.producer == producer, existing.sessionID == sessionID else {
                throw CommunicationError.unauthorized
            }
            return false
        }
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard let messaging, trackedTasks.count < 256 else { throw CommunicationError.capacityExceeded }
        let token = UUID()
        trackedTasks[reference] = .init(token: token, producer: producer, sessionID: sessionID)
        do {
            if !hasStaticTaskSubscription(from: producer) {
                let subscription = try await messaging.subscribe(
                    .init(
                        channel: "agent.task", protocolID: "agent.task.events.v1", sources: [producer],
                        scope: reference,
                        sessionID: sessionID))
                guard trackedTasks[reference]?.token == token else {
                    await subscription.cancel()
                    throw CancellationError()
                }
                trackedTasks[reference]?.dynamicSubscription = subscription
            }
            try Task.checkCancellation()
            return true
        } catch {
            if trackedTasks[reference]?.token == token { await stopTrackingTask(reference) }
            throw error
        }
    }
    func hasStaticTaskSubscription(from producer: AgentID) -> Bool {
        communicationPolicy.subscriptions.contains {
            $0.channel == "agent.task" && $0.protocol == "agent.task.events.v1"
                && $0.sources.contains(producer.rawValue)
        }
    }
    func stopTrackingTask(_ reference: String) async {
        if let owned = trackedTasks.removeValue(forKey: reference) { await owned.dynamicSubscription?.cancel() }
    }
    /// The receiver records each received peer message for tracing; the record never drives processing.
    func recordReceived(_ report: AgentTaskResponse, reference: String, input: AgentInput) async {
        do {
            let id =
                report.signal.flatMap { try? AgentTaskContent.decode($0).event?.eventID }
                ?? report.rejection?.eventID ?? input.id
            let records = try requireCommunications()
            try await records.enqueueAgentMessage(
                .init(
                    id: id, sender: input.metadata.source, receiver: descriptor.id.rawValue,
                    contract: AgentTaskResponse.contract, payload: try JSONEncoder().encode(report),
                    correlationID: reference, replyTo: report.rejection?.messageID ?? reference,
                    sourceSessionID: input.sessionID, dedupeKey: id))
            try await records.receiveAgentMessage(id, receiver: descriptor.id.rawValue, consumed: true)
            messageRecordFailure = nil
        } catch {
            messageRecordFailure = String(String(describing: error).prefix(1024))
        }
    }
    var containerFailures: [ContainerFailureEvent] = []
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
    var executionCancellationBarrier = false
    func setExecutionCancellationBarrier(_ held: Bool) {
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
                    value: try AgentPrompts.text("Shared/ExecutionFeedback", "interrupted"),
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
    var coordination: [String: AssistantInputCoordination] = [:]
    /// Replies cut off by an interrupt decision while still generating; consumed when their generation settles.
    var interruptedInputs: Set<String> = []
    var mergedResults: [String: [ChatMessage]] = [:]
    var semanticMessages: [String: AssistantInputMessage] = [:]
    var semanticAttachments: [String: [ChatMessage]] = [:]
    var semanticSequence: UInt64 = 0
    let clockDate = Date()
    let clockUptime = ProcessInfo.processInfo.systemUptime
    var blockedSessions: Set<String> = []
    var interruptedIntents: [String: [String]] = [:]
    var inputDecisionFeedback: (@Sendable (String) async -> Void)?
    func bindInputDecisionFeedback(_ callback: @escaping @Sendable (String) async -> Void) {
        inputDecisionFeedback = callback
    }
    let inputQueueStatus: @Sendable (Int, Int) async -> Void
    func publishInputQueue() async { await inputQueueStatus(queue.count, await decisionQueue.count) }
    let fullDuplex: Bool
    let inputDecision: AssistantInputDecision?
    let decisionLog: (@MainActor @Sendable (InputDecisionSnapshot, InputDecisionOutcome, Duration) -> Void)?
    struct DecisionTurn {
        let id: UUID
        let inputID: String
        let sessionID: String
        var assistant: String = ""
    }
    var decisionTurn: DecisionTurn?
    let decisionQueue = AssistantDecisionQueue()
    var interruptReceipts: [String] = []
    func beginDecisionTurn(_ input: AgentInput) {
        guard decisionTurn?.inputID != input.id else { return }
        decisionTurn = .init(id: UUID(), inputID: input.id, sessionID: input.sessionID)
    }
    let speechSessionID: String?
    var speechUtterances: Set<String> = []
    var interruptionWait: UUID?
    private var interruptionSpeechObserved = false
    private var onsetCandidateActive = false
    private var interruptionProbeElapsed = false
    private var speechCaptureGeneration: String?
    var interruptionWaitTask: Task<Void, Never>?
    /// 40 VAD windows of 512 samples at 16 kHz: how long after cleanup silence must hold before nobody is assumed
    /// to be speaking.
    static var interruptionProbeDuration: Duration { .milliseconds(1280) }

    func speechStarted(_ id: String) throws {
        guard lifecycle == .running else { return }
        guard speechUtterances.count < 32 || speechUtterances.contains(id) else {
            throw CommunicationError.capacityExceeded
        }
        speechUtterances.insert(id)
        if interruptionWait != nil {
            interruptionSpeechObserved = true
            interruptionWaitTask?.cancel()
            interruptionWaitTask = nil
        }
    }

    func speechEnded(_ id: String) {
        guard speechUtterances.remove(id) != nil else { return }
        finishInterruptionWaitIfReady()
    }

    func speechPublicationFailed(_ input: AgentInput, reason: String) {
        guard input.sessionID == speechSessionID, let turn = input.turn,
            speechUtterances.contains(turn.id)
        else { return }
        emit(.control("agent.error: speech delivery failed: \(reason)"), for: input)
        speechEnded(turn.id)
    }

    func clearSpeechUtterances() {
        speechUtterances.removeAll()
        finishInterruptionWaitIfReady()
    }

    func cancelInterruptionWait() {
        interruptionWaitTask?.cancel()
        interruptionWaitTask = nil
        interruptionWait = nil
        interruptionSpeechObserved = false
        interruptionProbeElapsed = false
    }

    func finishInterruptionWaitIfReady() {
        guard interruptionWait != nil, !executionCancellationBarrier, interruptionSpeechObserved,
            speechUtterances.isEmpty
        else { return }
        cancelInterruptionWait()
        drain()
    }

    /// Speech facts arrive only as the authenticated `perception.speech.activity.v1` Signal this Agent subscribes to.
    func receiveSpeechActivity(_ input: AgentInput, _ activity: SpeechActivity) async throws {
        guard input.sessionID == speechSessionID, lifecycle != .stopped else { return }
        switch activity.kind {
        case .captureStarted:
            if let generation = activity.generation { speechCaptureStarted(generation) }
            await listening?.republish()
            await refreshReplyActivity(force: true)
        case .captureStopped:
            if let generation = activity.generation { speechCaptureStopped(generation) }
        case .duplexSupport:
            if let supported = activity.fullDuplex { await listening?.captureDuplex(supported) }
        case .onsetStarted:
            onsetCandidateActive = true
        case .onsetCleared:
            onsetCandidateActive = false
            concludeInterruptionProbeIfSilent()
        case .onsetConfirmed:
            onsetCandidateActive = false
            if let utterance = activity.utterance { try speechStarted(utterance) }
        case .utteranceEnded:
            if let utterance = activity.utterance { speechEnded(utterance) }
        case .utterancesCleared:
            onsetCandidateActive = false
            clearSpeechUtterances()
        case .ended:
            onsetCandidateActive = false
            if let generation = speechCaptureGeneration { speechCaptureStopped(generation) }
            clearSpeechUtterances()
            await listening?.perceptionEnded()
        }
    }

    private func speechCaptureStarted(_ generation: String) {
        if let prior = speechCaptureGeneration, prior != generation {
            // Utterances of an earlier capture can no longer end by themselves.
            onsetCandidateActive = false
            speechUtterances.removeAll()
            if interruptionWait != nil { failInterruptionProbe("Speech capture changed during interruption wait") }
        }
        speechCaptureGeneration = generation
    }

    private func speechCaptureStopped(_ generation: String) {
        guard speechCaptureGeneration == generation else { return }
        speechCaptureGeneration = nil
        onsetCandidateActive = false
        if interruptionWait != nil {
            failInterruptionProbe("Speech capture stopped during interruption wait")
        }
    }

    /// The probe window has passed with no confirmed speech; a candidate still pending keeps the wait open until it
    /// confirms or clears.
    private func concludeInterruptionProbeIfSilent() {
        guard interruptionWait != nil, interruptionProbeElapsed, !interruptionSpeechObserved,
            !onsetCandidateActive
        else { return }
        cancelInterruptionWait()
        drain()
    }

    private func failInterruptionProbe(_ reason: String) {
        Logger(subsystem: "dev.mobileharness", category: "AssistantSpeech").error("\(reason, privacy: .public)")
        if let input = queue.inputs.first(where: { $0.sessionID == speechSessionID }) {
            emit(.control("agent.error: \(reason)"), for: input)
        }
        cancelInterruptionWait()
        drain()
    }

    private func beginInterruptionWait(_ id: UUID) {
        guard interruptionWait == id else { return }
        if interruptionSpeechObserved {
            finishInterruptionWaitIfReady()
            return
        }
        guard speechCaptureGeneration != nil else {
            failInterruptionProbe("Speech capture unavailable for interruption wait")
            return
        }
        interruptionProbeElapsed = false
        interruptionWaitTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.interruptionProbeDuration) } catch { return }
            await self?.interruptionProbeDurationPassed(id)
            do { try await Task.sleep(for: .seconds(10) - Self.interruptionProbeDuration) } catch { return }
            await self?.interruptionProbeTimedOut(id)
        }
    }

    private func interruptionProbeDurationPassed(_ id: UUID) {
        guard interruptionWait == id else { return }
        interruptionProbeElapsed = true
        concludeInterruptionProbeIfSilent()
    }

    private func interruptionProbeTimedOut(_ id: UUID) {
        guard interruptionWait == id else { return }
        failInterruptionProbe("Speech interruption observation stalled")
    }
    var inputInterruption: (@Sendable (String) async throws -> Void)?
    func bindInputInterruption(_ callback: @escaping @Sendable (String) async throws -> Void) {
        inputInterruption = callback
    }
    /// All interruption producers use this entry; execution cleanup is injected by the session owner.
    public func requestInterrupt(
        _ signal: AssistantInterrupt, sessionID: String, source: String = "runtime"
    ) async throws -> AssistantInterruptResult {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        let key = "\(source)|\(sessionID)|\(signal.id)"
        guard !interruptReceipts.contains(key) else { return .duplicate }
        interruptReceipts.append(key)
        if interruptReceipts.count > 128 { interruptReceipts.removeFirst() }
        let target: UUID
        switch signal.target {
        case .current:
            guard let turn = decisionTurn, turn.sessionID == sessionID else { return .noTarget }
            target = turn.id
        case .reply(let id): target = id
        }
        let active = await hasActiveReply(sessionID: sessionID)
        guard active, decisionTurn?.sessionID == sessionID, decisionTurn?.id == target,
            !executionCancellationBarrier, !hostCancellationInProgress
        else { return .targetExpired }
        guard let inputInterruption else { throw CommunicationError.unavailableTarget }
        // Claim synchronously after the final target check, before crossing the cleanup boundary.
        executionCancellationBarrier = true
        let victim = decisionTurn?.inputID
        decisionTurn = nil
        worker?.cancel()
        let speechWait = fullDuplex && sessionID == speechSessionID ? UUID() : nil
        if let speechWait {
            cancelInterruptionWait()
            interruptionWait = speechWait
            interruptionSpeechObserved = !speechUtterances.isEmpty
        }
        defer {
            executionCancellationBarrier = false
            finishInterruptionWaitIfReady()
            drain()
        }
        if let victim { interruptedInputs.insert(victim) }
        do {
            try await inputInterruption(sessionID)
            if let speechWait, interruptionWait == speechWait, lifecycle == .running {
                beginInterruptionWait(speechWait)
            }
        } catch {
            cancelInterruptionWait()
            throw error
        }
        if let victim { try await markInterruptedAfterCleanup(victim) }
        return .interrupted
    }

    /// Generation may have finished before the interrupt, leaving only playback to cut off; the reply then
    /// already holds a terminal state that must still read as interrupted.
    private func markInterruptedAfterCleanup(_ id: String) async throws {
        let state = try await conversations.readCurrent().current.turns.first { $0.id == id }?.state
        guard state == .completed else { return }
        interruptedInputs.remove(id)
        try await conversations.finish(id, state: .interrupted, reason: "interrupted")
    }

    public func currentReplyID(sessionID: String) async -> UUID? {
        guard let turn = decisionTurn, turn.sessionID == sessionID else { return nil }
        let active = await hasActiveReply(sessionID: sessionID)
        return active && decisionTurn?.id == turn.id ? turn.id : nil
    }

    func completeInputDecision(
        _ snapshot: InputDecisionSnapshot, outcome result: InputDecisionOutcome, duration: Duration
    ) async {
        guard !Task.isCancelled, lifecycle != .stopped else { return }
        let input = snapshot.input
        if result.signalStatus == "interrupted" { await inputDecisionFeedback?(input.id) }
        if result.signalStatus == "interrupt_failed" {
            emit(.control("decision.error: \(result.reason ?? "Interruption failed")"), for: input)
        }
        if var evidence = coordination[input.id] {
            evidence.interrupt = result.modelResult
            evidence.route = result.route.rawValue
            coordination[input.id] = evidence
            do { try await conversations.recordCoordination(evidence, for: input.id) } catch {
                emit(.control("agent.historyError: \(error)"), for: input)
            }
        }
        await decisionLog?(snapshot, result, duration)
    }

    var lifecycle: AgentLifecycle = .registered
    var queue: SignalInbox
    var admitting = 0
    var admittingInputs: [String: String] = [:]
    var cancelledAdmissions: Set<String> = []
    struct ContinuationRound: Sendable {
        let request: ChatRequest
        let inputText: String
        let ordinal: Int
        let budget: AgentTaskBudget
        let protectedSuffixCount: Int
        let readyAt: Date
        let capability: any ChatCapability
        let requestTaskID: String?
        let boundaryMessages: [ChatMessage]
        let language: String
    }
    var continuationRounds: [String: ContinuationRound] = [:]
    var currentOrdinal = 0
    var roundCoordinator: AgentRoundCoordinator?

    var processed = 0
    let capacity: Int
    let chatProvider: @Sendable () async throws -> any ChatCapability
    let communicationPolicy: CommunicationDeclaration
    var requestSkillIDs: [String] = []
    var modelCapabilities: CapabilityRegistry
    let usesSkills: Bool
    var requestCatalog: CapabilityRegistry?
    let language: @Sendable () -> String
    let prompt: @Sendable (CapabilityRegistry) throws -> String
    var hostCancellationInProgress = false
    var hostCancellationSession: String?
    var reportHostCancellationFailure = false
    var hostCancelledInput: (id: String, round: String?)?
    var worker: Task<Void, Never>?
    var activeInput: AgentInput? { didSet { scheduleReplyActivityRefresh() } }
    var publishedReplyActivity: Bool?
    var replyActivityRefreshing = false
    var replyActivityDirty = false
    var begunInputID: String?
    var begunSession: String?
    var begunTurn: AgentTurn?
    var begunRoundID: String?
    var outputSequence: UInt64 = 0
    let conversations: AssistantHistoryStore
    let observations:
        @Sendable ([AssistantChatObservation], AgentInput, any ChatCapability) async throws -> [ChatMessage]
    let modelName: @Sendable () async throws -> String
    var generationFinishReason: String?
    struct RoundCall {
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
    struct RoundSuspended: Error {}
    struct PendingRound {
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
        let finishReason: String?
        let bindings: [String: String]
        let imageScopes: [String: String]
        let imageIDs: Set<String>
        let language: String
        var queued = false
        var cancelled = false
        var publishing = false
    }
    var pendingRounds: [String: PendingRound] = [:] { didSet { scheduleReplyActivityRefresh() } }
    var settlementAdmissions: Set<String> = []
    var batchMembers: [String: [AgentInput]] = [:]
    var batchTexts: [String: String] = [:]
    var roundID: String?
    var roundCalls: [RoundCall] = []
    var roundReceipt: GenerationRoundResult?
    var generationCalls = 0
    var roundContinuationInputText = ""
    var roundSuffixCount = 1
    var budget: AgentTaskBudget?
    var resultBytes = 0
    var feedbackFailure: String?

    var pendingInteractions: [String] = []
    var foregroundInteraction: String?
    let presentsReply: Bool
    var replyInputs: Set<String> = []
    var inputInteractions: [String: [AgentTaskView]] = [:]
    var immediateInputs: Set<String> = []
    var routingWorkers: [String: Task<Void, Never>] = [:]
    var routingSessions: [String: String] = [:]
    struct PeerTaskNotice {
        let input: AgentInput
        let scopeID: String
        let originDialog: String
        let kind: AgentTaskEvent.Kind?
        let interactionID: String?
        let text: String
    }
    var peerNotices: [PeerTaskNotice] = []
    var activePeerTaskNoticeID: String?

    static var beginReply: InternalAction {
        InternalAction(
            domain: "UI", module: "Caption", function: "beginReplyTurn", channel: "Display")
    }
    var replyWaitingRequest: String?
    var replyPresentation: (@Sendable (Bool) async -> Void)?
    /// Generic request-latency facts. The role owns content and calls its own presentation tools.
    func bindReplyWaiting(_ callback: @escaping @Sendable (Bool) async -> Void) { replyPresentation = callback }
    static var replyWaiting: InternalAction {
        InternalAction(
            domain: "UI", module: "Expression", function: "setReplyWaiting", channel: "Display",
            required: ["enabled", "requestID"])
    }
    static var playback: InternalAction {
        InternalAction(
            domain: "Speech", module: "Playback", function: "speak", channel: "Speech", required: ["audioID"])
    }
    static var caption: InternalAction {
        InternalAction(
            domain: "UI", module: "Caption", function: "print", channel: "Display", required: ["text"])
    }

    let uiHome: UIHomeContainer?
    let uiSessionID: String?
    var uiInputs = AgentUIInputs()
    var uiTextOrdinal: UInt64 = 0
    let stateContext: AgentStateContext?
    let listening: (any ListeningModeControlling)?
    /// Handlers for the triggers `Agent.json` declares; installed at the end of initialization.
    private let triggerSlot = Mutex<AgentStateTriggers>(AgentStateTriggers())
    var stateTriggers: AgentStateTriggers { triggerSlot.withLock { $0 } }
    var ephemeralImageIDs: Set<String> = []
    var resourceBindings: [String: String] = [:]
    var imageScopes: [String: String] = [:]

    public init(
        stateContext: AgentStateContext? = nil,
        speechOutput: (any AssistantSpeechProducing)? = nil,
        inputDecision: AssistantInputDecision? = nil, fullDuplex: Bool = false,
        decisionLog: (@MainActor @Sendable (InputDecisionSnapshot, InputDecisionOutcome, Duration) -> Void)? = nil,
        inputQueueStatus: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
        uiHome: UIHomeContainer? = nil, uiSessionID: String? = nil, speechSessionID: String? = nil,
        capacity: Int = 32, presentsReply: Bool = false,
        outputCapacity: Int = 256, chat: (any ChatCapability)? = nil,
        chatProvider: (@Sendable () async throws -> any ChatCapability)? = nil,
        configuration: AgentConfiguration? = nil,
        conversations: AssistantHistoryStore = AssistantHistoryStore(),
        communications: (any AgentMessageRepository)? = nil,
        listening: (any ListeningModeControlling)? = nil,
        modelName: @escaping @Sendable () async throws -> String = { "Unspecified model" },
        observations:
            @escaping @Sendable ([AssistantChatObservation], AgentInput, any ChatCapability) async throws ->
            [ChatMessage] =
            { _, _, _ in [] },
        context: AgentContextRepository<State>,
        capabilities: CapabilityRegistry? = nil,
        prompt: (@Sendable (CapabilityRegistry) throws -> String)? = nil,
        language: @escaping @Sendable () -> String = { "en" }
    ) throws {
        self.inputQueueStatus = inputQueueStatus
        self.fullDuplex = fullDuplex
        self.inputDecision = inputDecision
        self.decisionLog = decisionLog
        self.speechOutput = speechOutput
        self.uiHome = uiHome
        self.uiSessionID = uiSessionID
        self.speechSessionID = speechSessionID
        guard uiHome == nil || uiSessionID != nil else { throw CommunicationError.invalidPayload }
        guard (1...8191).contains(capacity), (1...8192).contains(outputCapacity) else {
            throw CommunicationError.invalidPayload
        }
        let skillStream = AsyncStream<AgentTaskSkillState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        skillUpdates = skillStream.stream
        skillContinuation = skillStream.continuation
        self.stateContext = stateContext
        self.presentsReply = presentsReply
        queue = try SignalInbox(capacity: capacity + (fullDuplex ? 33 : 1))
        self.contextRepository = context
        guard contextRepository.agentID == State.agentID else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: State.configurationName)
        guard configuration.agentID == State.agentID else { throw AgentConfigurationError.identityMismatch }
        let runtimeCapabilities = try State.runtimeCapabilities(capabilities ?? configuration.capabilities)
        descriptor = AgentDescriptor(
            category: configuration.category,
            id: configuration.agentID, name: State.configurationName,
            inputs: configuration.communication.inputKinds,
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
        if supportsSkills {
            // The `task` variable's trigger needs its declaration; a missing one is a configuration error.
            guard
                try AgentConfigurations.stateSchema(named: State.configurationName).declaration(boundTo: "task") != nil
            else { throw AgentConfigurationError.invalidField("task state declaration") }
        }
        if supportsSkills, let communications {
            guard conversations.tasks.storageScope == communications.storageScope else {
                throw RecordStorageError.invalidRecord
            }
        }
        taskRecords = supportsSkills ? conversations.tasks : nil
        self.communicationPolicy = configuration.communication
        self.listening = listening
        self.modelCapabilities = runtimeCapabilities
        _ = try AgentPrompts.load(named: State.configurationName)
        self.language = language
        self.prompt = prompt ?? State.systemPrompt
        self.observations = observations
        self.conversations = conversations
        self.communications = communications
        self.modelName = modelName
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
        var handlers: [String: AgentStateTriggerHandler] = [:]
        handlers["task"] = { [weak self] write in
            guard let self else { throw CommunicationError.unavailableTarget }
            return try await self.taskTrigger(write)
        }
        handlers["listening"] = { [weak self] write in
            guard let self else { throw CommunicationError.unavailableTarget }
            try await self.applyListeningMode(write)
            return .publish
        }
        let triggers = try AgentStateTriggers(handlers)
        try triggers.validate(schema: AgentConfigurations.stateSchema(named: State.configurationName))
        triggerSlot.withLock { $0 = triggers }
    }

    private func applyListeningMode(_ write: AgentStateWrite) async throws {
        guard let listening else { return }
        let mode = ListeningMode(variable: write.new)
        let reply =
            write.source == .model && mode == .quiet && listening.mode != .quiet
            ? activeInput.flatMap { $0.id == write.inputID && $0.sessionID == write.sessionID ? $0 : nil }
            : nil
        try await listening.apply(mode, source: write.source, wakeCondition: write.wakeCondition)
        if let reply {
            // Join only audio production here. The caller still owns generation and round settlement.
            await speechOutput?.cancel(input: reply)
        }
    }
    /// Shared with explicit model diagnostics; capability declarations remain in role JSON.
    public nonisolated static func systemPrompt(capabilities: CapabilityRegistry) throws -> String {
        try State.systemPrompt(capabilities)
    }

    /// Complete fixed capabilities, including the State's own grants and controls.
    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try State.runtimeCapabilities(model)
    }

    /// Speech and caption grants shared by every chat State; States add their own on top.
    nonisolated static func chatRuntimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(
            internalActions: [playback, beginReply, caption, replyWaiting]
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
}
