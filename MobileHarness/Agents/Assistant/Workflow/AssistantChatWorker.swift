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
    /// Fills unadmitted call slots only once the execution owner has closed the round.
    func settleCancelledCalls(_ parked: inout PendingRound, roundID: String) async throws {
        for index in parked.calls.indices where parked.calls[index].result == nil {
            let result = ToolResult(
                callID: parked.calls[index].id,
                value: try AgentPrompts.text("Shared/ExecutionFeedback", "interrupted"),
                isError: true, failureCode: "cancelled", completion: .completed, roundID: roundID)
            if parked.calls[index].tool {
                try await conversations.recordToolOutcome(
                    result.callID, for: parked.input.id, state: .cancelled,
                    output: result.value, error: result.failureCode)
            }
            parked.calls[index].result = result
        }
    }

    struct ActiveInterruption {
        let id: String
        let sessionID: String
        let replyInputID: String
        var replyActions: ReplyActions?
        var generationJoined = false
        var cleanupConfirmed = false
        var settling = false
    }
    var activeInterruption: ActiveInterruption?
    private var interruptionCleanupWatchdog: Task<Void, Never>?
    func retireExecutionInterruption() {
        interruptionCleanupWatchdog?.cancel()
        interruptionCleanupWatchdog = nil
        activeInterruption = nil
        executionCancellationBarrier = false
    }
    var executionRoundSources: [String: ProcessingContext] = [:]
    var executionStartedCalls: [String: Set<String>] = [:]
    private var closedExecutionRounds: [String] = []
    func retireExecutionFeedback(_ id: String) {
        executionRoundSources[id] = nil
        executionStartedCalls[id] = nil
        closedExecutionRounds.append(id)
        if closedExecutionRounds.count > 128 { closedExecutionRounds.removeFirst() }
    }
    func hasClosedExecutionRound(_ id: String) -> Bool { closedExecutionRounds.contains(id) }
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
    let keywordLog: (@MainActor @Sendable (DecisionLogItem) -> Void)?
    struct DecisionTurn {
        let id: UUID
        let inputID: String
        let sessionID: String
        let startedAt = SpeechSignalClock.offset(at: .now)
        var assistant: String = ""
        var replyActions: ReplyActions?
    }
    struct ReplyActions {
        let requestID: String
        // The ordered output reader submits these to the scheduler in this order.
        private var actions: [(id: String, path: ActionPath, source: Range<Int>)] = []
        private var completed: Set<String> = []

        init(requestID: String) { self.requestID = requestID }

        mutating func append(id: String, path: ActionPath, source: Range<Int>) {
            actions.append((id, path, source))
        }

        mutating func confirm(_ result: ActionResult) {
            guard result.roundID == requestID, result.status == .succeeded, result.effect == .contractCompleted,
                let id = result.callID, actions.contains(where: { $0.id == id && $0.path == result.path })
            else { return }
            completed.insert(id)
        }

        var completedActions: [(id: String, source: Range<Int>)] {
            actions.compactMap { completed.contains($0.id) ? ($0.id, $0.source) : nil }
        }
    }
    func recordReplyActionCompletion(_ result: ActionResult) {
        if activeInterruption?.replyInputID == result.inputID,
            activeInterruption?.sessionID == result.owner.sessionID,
            activeInterruption?.cleanupConfirmed == false
        {
            activeInterruption?.replyActions?.confirm(result)
        } else if decisionTurn?.inputID == result.inputID, decisionTurn?.sessionID == result.owner.sessionID {
            decisionTurn?.replyActions?.confirm(result)
        }
    }
    var decisionTurn: DecisionTurn?
    let decisionQueue = AssistantDecisionQueue()
    var interruptReceipts: [String] = []
    var keywordInterruptedTurns: [String] = []
    let interruptionKeywordLabels: Set<String>
    var speechTerminals: [String] = []
    private var retiredSpeechGenerations: [String] = []
    var keywordCleanup: (id: String, task: Task<Void, Never>)?
    func beginDecisionTurn(_ input: AgentInput) {
        guard decisionTurn?.inputID != input.id else { return }
        decisionTurn = .init(id: UUID(), inputID: input.id, sessionID: input.sessionID)
    }
    let speechSessionID: String?
    var speechUtterances: Set<String> = []
    private struct ContinuationObservation: Equatable {
        let id: UUID
        let since: Duration
    }
    private var continuationObservation: ContinuationObservation?
    var interruptionWait: UUID? { continuationObservation?.id }
    private var onsetCandidateActive = false
    private var continuationReady = false
    private var interruptionOnsetCandidate = false
    private var interruptionUtterances: Set<String> = []
    // Retained through the first speech batch dispatch to separate later finals from that batch.
    var interruptionBatchStartedAt: Duration?
    private var speechCaptureGeneration: String?
    private var speechWindowSequence: UInt64 = 0
    private var speechOnsetRevision: UInt64 = 0
    private var continuationWatchdog: Task<Void, Never>?

    func noteSpeechTerminal(_ input: AgentInput) -> Bool {
        guard input.sessionID == speechSessionID, let turn = input.turn,
            input.payload.speechRecognition?.kind == .final, !speechTerminals.contains(turn.id)
        else { return false }
        speechTerminals.append(turn.id)
        if speechTerminals.count > 128 { speechTerminals.removeFirst() }
        if continuationObservation != nil, let generation = input.payload.speechRecognition?.generation,
            speechCaptureGeneration == nil || speechCaptureGeneration == generation,
            !retiredSpeechGenerations.contains(generation), !isAfterSpeechWindow(input)
        {
            interruptionUtterances.insert(turn.id)
        }
        return true
    }

    func speechStarted(_ id: String) throws {
        guard lifecycle == .running, !speechTerminals.contains(id) else { return }
        guard speechUtterances.count < 32 || speechUtterances.contains(id) else {
            throw CommunicationError.capacityExceeded
        }
        speechUtterances.insert(id)
    }

    func speechEnded(_ id: String) {
        speechUtterances.remove(id)
        interruptionUtterances.remove(id)
        keywordInterruptedTurns.removeAll { $0 == id }
        finishInterruptionWaitIfReady()
    }

    func speechPublicationFailed(_ input: AgentInput, reason: String) {
        guard noteSpeechTerminal(input), let turn = input.turn else { return }
        emit(.control("agent.error: speech delivery failed: \(reason)"), for: input)
        speechEnded(turn.id)
    }

    func clearSpeechUtterances() {
        onsetCandidateActive = false
        speechUtterances.removeAll()
        interruptionOnsetCandidate = false
        interruptionUtterances.removeAll()
        finishInterruptionWaitIfReady()
    }

    func isAfterSpeechWindow(_ input: AgentInput) -> Bool {
        guard input.sessionID == speechSessionID, let cutoff = interruptionBatchStartedAt,
            let preceding = input.payload.speechRecognition?.oldestWindowBeforeOnset
        else { return false }
        return preceding >= cutoff
    }

    func cancelInterruptionWait(preserveBatchCutoff: Bool = false) {
        if !preserveBatchCutoff { interruptionBatchStartedAt = nil }
        continuationWatchdog?.cancel()
        continuationWatchdog = nil
        continuationObservation = nil
        continuationReady = false
    }

    func finishInterruptionWaitIfReady() {
        guard continuationObservation != nil, continuationReady, !executionCancellationBarrier,
            !interruptionOnsetCandidate, interruptionUtterances.isEmpty
        else { return }
        cancelInterruptionWait(preserveBatchCutoff: true)
        drain()
    }

    var preservingInterruptionSpeechAdmissions: Bool {
        executionCancellationBarrier && continuationObservation != nil
    }

    func isTrackedSpeechFinal(_ input: AgentInput) -> Bool {
        guard input.sessionID == speechSessionID, input.metadata.origin == .agent,
            input.metadata.source == AgentID.speechPerception.rawValue,
            let recognition = input.payload.speechRecognition, recognition.kind == .final, let turn = input.turn
        else { return false }
        return speechUtterances.contains(turn.id)
            || (recognition.generation != nil && recognition.generation == speechCaptureGeneration)
    }

    /// VAD is ordered within its channel. ASR and keyword events correlate via the utterance ID.
    func receiveSpeechActivity(_ input: AgentInput, _ activity: SpeechActivity) throws {
        guard input.sessionID == speechSessionID, lifecycle != .stopped else { return }
        if activity.kind == .captureStarted {
            speechCaptureStarted(activity.generation)
            return
        }
        guard activity.generation == speechCaptureGeneration else { return }
        switch activity.kind {
        case .captureStarted:
            break
        case .captureStopped:
            speechCaptureStopped(activity.generation)
        case .vadProgress:
            guard let sequence = activity.sequence, sequence > speechWindowSequence else { return }
            speechWindowSequence = sequence
            guard let observation = continuationObservation, activity.onsetRevision == speechOnsetRevision,
                let oldest = activity.oldestWindow, oldest >= observation.since
            else { return }
            continuationReady = true
            continuationWatchdog?.cancel()
            continuationWatchdog = nil
            finishInterruptionWaitIfReady()
        case .onsetStarted, .onsetCleared, .onsetConfirmed:
            guard let revision = activity.onsetRevision, revision == speechOnsetRevision + 1 else { return }
            if let utterance = activity.utterance { try speechStarted(utterance) }
            speechOnsetRevision = revision
            onsetCandidateActive = activity.kind == .onsetStarted
            if let observation = continuationObservation {
                let inWindow = activity.oldestWindowBeforeOnset.map { $0 < observation.since } ?? !continuationReady
                if let utterance = activity.utterance, interruptionOnsetCandidate || inWindow,
                    speechUtterances.contains(utterance)
                {
                    interruptionUtterances.insert(utterance)
                }
                interruptionOnsetCandidate = onsetCandidateActive && inWindow
            }
            finishInterruptionWaitIfReady()
        }
    }

    private func speechCaptureStarted(_ generation: String) {
        guard speechCaptureGeneration != generation, !retiredSpeechGenerations.contains(generation) else { return }
        if let previous = speechCaptureGeneration { speechCaptureStopped(previous) }
        speechCaptureGeneration = generation
        speechWindowSequence = 0
        speechOnsetRevision = 0
        resetContinuationProgress()
    }

    private func speechCaptureStopped(_ generation: String) {
        guard speechCaptureGeneration == generation else { return }
        speechCaptureGeneration = nil
        retiredSpeechGenerations.append(generation)
        if retiredSpeechGenerations.count > 32 { retiredSpeechGenerations.removeFirst() }
        if continuationObservation != nil { reportInterruptionFailure("Speech capture stopped during interruption") }
        resetContinuationProgress()
        clearSpeechUtterances()
    }

    private func resetContinuationProgress() {
        continuationReady = false
        if continuationObservation != nil { startContinuationWatchdog() }
    }

    private func startContinuationWatchdog() {
        continuationWatchdog?.cancel()
        guard let probe = continuationObservation else { return }
        continuationWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await self?.continuationStalled(probe)
        }
    }

    private func continuationStalled(_ probe: ContinuationObservation) {
        guard continuationObservation == probe, !continuationReady else { return }
        reportInterruptionFailure("Speech interruption observation stalled")
    }

    func reportInterruptionFailure(_ reason: String, cleanup: Bool = false) {
        let code = cleanup ? "interruption.cleanup" : "interruption.capture"
        let scope = activeInterruption?.id ?? continuationObservation?.id.uuidString ?? UUID().uuidString
        let input = AgentInput(
            id: UUID().uuidString, sessionID: activeInterruption?.sessionID ?? speechSessionID ?? "assistant",
            payload: .event("interruption.failure"))
        let diagnostic = AgentFailureDiagnostic(category: .runtime, code: code, detail: reason)
        emit(.control("agent.error: \(reason)"), for: input, failure: diagnostic)
        guard let uiHome else { return }
        let copy = AppLanguage(preferredLanguage: language())
        let issue = ExecutionIssue(
            id: scope + "." + code, title: copy.text("Assistant"), source: descriptor.id.rawValue,
            message: reason, failureCode: code, inputID: input.id,
            userMessage: cleanup
                ? copy.text("Automatic replies are paused because Action cleanup could not be confirmed.")
                : copy.text("Waiting for microphone capture to resume after interruption."))
        Task { @MainActor in uiHome.notices.offerToast(issue, placement: .toast) }
    }

    func interruptionGenerationJoined(_ id: String) async throws {
        guard activeInterruption?.id == id else { return }
        activeInterruption?.generationJoined = true
        try await finishExecutionInterruption()
    }

    func finishExecutionInterruption() async throws {
        guard let current = activeInterruption, current.cleanupConfirmed, current.generationJoined, !current.settling
        else { return }
        activeInterruption?.settling = true
        do {
            if let reply = current.replyActions {
                let actions = reply.completedActions
                let truncated = try await conversations.recordReplyTruncation(
                    .init(roundID: reply.requestID, completedCallIDs: actions.map(\.id)),
                    fragments: actions.map(\.source), inputID: current.replyInputID, requestID: reply.requestID)
                let key = reply.requestID + ".tools"
                if let truncated, let queued = semanticAttachments[key]?.first, queued.role == .assistant {
                    let templates = try AgentPrompts.$language.withValue(AgentPrompts.normalizedLanguage(language())) {
                        try AgentPrompts.load(named: State.configurationName)
                    }
                    semanticAttachments[key]?[0] = .init(
                        role: .assistant,
                        content: try AssistantHistoryProjection.interruptedText(truncated, templates: templates),
                        toolCalls: queued.toolCalls)
                }
            }
            try await markInterruptedAfterCleanup(current.replyInputID)
        } catch {
            if activeInterruption?.id == current.id { activeInterruption?.settling = false }
            throw error
        }
        guard activeInterruption?.id == current.id else { return }
        for (id, source) in executionRoundSources
        where source.sessionID == current.sessionID && pendingRounds[id] == nil {
            retireExecutionFeedback(id)
        }
        retireExecutionInterruption()
        finishInterruptionWaitIfReady()
        drain()
    }

    var inputInterruption: (@Sendable (String, String) async throws -> Void)?
    func bindInputInterruption(_ callback: @escaping @Sendable (String, String) async throws -> Void) {
        inputInterruption = callback
    }

    func canRunInterruptDecision(target: UUID, sessionID: String) -> Bool {
        lifecycle == .running && !executionCancellationBarrier && !hostCancellationInProgress
            && decisionTurn?.id == target && decisionTurn?.sessionID == sessionID
    }
    /// All interruption producers use this entry; execution cleanup is injected by the session owner.
    public func requestInterrupt(
        _ signal: AssistantInterrupt, sessionID: String, source: String = "runtime"
    ) async throws -> AssistantInterruptResult {
        try await admitInterrupt(signal, sessionID: sessionID, source: source, keyword: nil)
    }

    func admitInterrupt(
        _ signal: AssistantInterrupt, sessionID: String, source: String, keyword: (AgentInput, SpeechKeywordMatch)?
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
        guard !executionCancellationBarrier, !hostCancellationInProgress else { return .targetExpired }
        let active = await hasActiveReply(sessionID: sessionID)
        guard active, let turn = decisionTurn, turn.sessionID == sessionID, turn.id == target,
            !executionCancellationBarrier, !hostCancellationInProgress
        else { return .targetExpired }
        guard let inputInterruption else { throw CommunicationError.unavailableTarget }
        if let (_, keyword) = keyword {
            guard lifecycle == .running, listening?.isListening != false,
                !retiredSpeechGenerations.contains(keyword.generation),
                speechCaptureGeneration == nil || speechCaptureGeneration == keyword.generation,
                !keywordInterruptedTurns.contains(keyword.utterance),
                keyword.onset >= turn.startedAt
            else { return .targetExpired }
            try speechStarted(keyword.utterance)
        }
        // Install both gates at admission, before crossing any cleanup boundary.
        executionCancellationBarrier = true
        let victim = turn.inputID
        let id = signal.id.uuidString
        let admittedAt = ContinuousClock.now
        activeInterruption = ActiveInterruption(
            id: id, sessionID: sessionID, replyInputID: victim, replyActions: turn.replyActions)
        interruptionCleanupWatchdog?.cancel()
        interruptionCleanupWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await self?.interruptionCleanupStalled(id)
        }
        for round in pendingRounds.keys where pendingRounds[round]?.input.sessionID == sessionID {
            pendingRounds[round]?.cancelled = true
        }
        decisionTurn = nil
        interruptedInputs.insert(victim)
        worker?.cancel()
        // Only an accepted interruption against an active reply opens the 64-window post-interruption buffer.
        if fullDuplex, sessionID == speechSessionID {
            let cutoff = SpeechSignalClock.offset(at: admittedAt)
            continuationObservation = .init(id: signal.id, since: cutoff)
            interruptionBatchStartedAt = cutoff
            interruptionOnsetCandidate = onsetCandidateActive
            interruptionUtterances = speechUtterances
            resetContinuationProgress()
        }
        async let stopDecision: Void = decisionQueue.cancelClassification(target: target, sessionID: sessionID)
        if let (input, keyword) = keyword {
            if !speechTerminals.contains(keyword.utterance) {
                keywordInterruptedTurns.append(keyword.utterance)
                if keywordInterruptedTurns.count > 128 { keywordInterruptedTurns.removeFirst() }
            }
            keywordCleanup = (
                id,
                Task { [weak self] in
                    guard let self else { return }
                    await self.completeKeywordInterruption(
                        inputInterruption, input: input, match: keyword, id: id)
                }
            )
        } else {
            try await confirmInterruption(inputInterruption, sessionID: sessionID, id: id)
        }
        await stopDecision
        return .interrupted
    }

    private func completeKeywordInterruption(
        _ inputInterruption: @Sendable (String, String) async throws -> Void,
        input: AgentInput, match: SpeechKeywordMatch, id: String
    ) async {
        defer { if keywordCleanup?.id == id { keywordCleanup = nil } }
        var failure: String?
        do { try await confirmInterruption(inputInterruption, sessionID: input.sessionID, id: id) } catch {
            failure = String(describing: error)
        }
        guard lifecycle != .stopped, !Task.isCancelled else { return }
        let detection = match.detection
        await keywordLog?(
            .init(
                id: input.id + ".keyword", source: descriptor.id.rawValue, inputText: match.keyword,
                duration: (detection?.completedAt ?? match.matchedAt) - match.onset, route: .keyword, modelResult: nil,
                adoptedResult: failure == nil ? .interrupt : .enqueue,
                signalStatus: failure == nil ? "interrupted" : "interrupt_failed", reason: failure, requests: [],
                modelName: detection?.modelName ?? detection?.modelID, modelID: detection?.modelID,
                inferenceDuration: detection?.inferenceDuration))
    }

    private func confirmInterruption(
        _ inputInterruption: @Sendable (String, String) async throws -> Void, sessionID: String, id: String
    ) async throws {
        do {
            try await inputInterruption(sessionID, id)
            guard activeInterruption?.id != id else { throw CommunicationError.unavailableTarget }
        } catch {
            if activeInterruption?.id == id {
                interruptionCleanupWatchdog?.cancel()
                interruptionCleanupWatchdog = nil
                reportInterruptionFailure("Could not confirm interruption cleanup: \(error)", cleanup: true)
            }
            throw error
        }
    }

    private func interruptionCleanupStalled(_ id: String) {
        guard activeInterruption?.id == id, lifecycle == .running else { return }
        reportInterruptionFailure("Action cleanup has not been confirmed. Automatic replies are paused.", cleanup: true)
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
    var admittingSpeechFinals: Set<String> = []
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
    var activeInput: AgentInput?
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
        var receipt: ExecutionEnd?
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
    var pendingRounds: [String: PendingRound] = [:]
    var settlementAdmissions: Set<String> = []
    var batchMembers: [String: [AgentInput]] = [:]
    var batchTexts: [String: String] = [:]
    var roundID: String?
    var roundCalls: [RoundCall] = []
    var roundReceipt: ExecutionEnd?
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
    let listening: (any ListeningControlling)?
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
        keywordLog: (@MainActor @Sendable (DecisionLogItem) -> Void)? = nil,
        inputQueueStatus: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
        uiHome: UIHomeContainer? = nil, uiSessionID: String? = nil, speechSessionID: String? = nil,
        capacity: Int = 32, presentsReply: Bool = false,
        outputCapacity: Int = 256, chat: (any ChatCapability)? = nil,
        chatProvider: (@Sendable () async throws -> any ChatCapability)? = nil,
        configuration: AgentConfiguration? = nil,
        conversations: AssistantHistoryStore = AssistantHistoryStore(),
        communications: (any AgentMessageRepository)? = nil,
        listening: (any ListeningControlling)? = nil,
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
        self.keywordLog = keywordLog
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
        interruptionKeywordLabels = State.agentID == .assistant ? try InterruptionKeywordPolicy.load() : []
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
            try await self.applyListeningState(write)
            return .publish
        }
        let triggers = try AgentStateTriggers(handlers)
        try triggers.validate(schema: AgentConfigurations.stateSchema(named: State.configurationName))
        triggerSlot.withLock { $0 = triggers }
    }

    private func applyListeningState(_ write: AgentStateWrite) async throws {
        guard let listening else { return }
        let enabled = write.new != "false"
        let reply =
            write.source == .model && !enabled && listening.isListening
            ? activeInput.flatMap { $0.id == write.inputID && $0.sessionID == write.sessionID ? $0 : nil }
            : nil
        try await listening.apply(enabled, source: write.source, wakeCondition: write.wakeCondition)
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
