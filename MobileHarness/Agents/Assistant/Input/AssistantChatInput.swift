import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

struct InterruptionKeywordPolicy: Decodable {
    private let version: Int
    private let labels: [String]

    static func load() throws -> Set<String> {
        let path = "Agents/Assistant/Input/InterruptionKeywords.json"
        let policy = try JSONDecoder().decode(Self.self, from: AgentConfigurations.data(path))
        let labels = Set(policy.labels)
        guard policy.version == 1, (1...32).contains(labels.count), labels.count == policy.labels.count,
            labels.allSatisfy({ (1...128).contains($0.utf8.count) })
        else { throw AgentConfigurationError.invalidField(path) }
        return labels
    }
}

extension AssistantChatWorker {
    public func receive(_ input: AgentInput) async throws {
        try await receive(input, awakened: false)
    }

    func receiveAwakeningSpeech(_ input: AgentInput) async throws {
        try await receive(input, awakened: true)
    }

    private func receive(_ input: AgentInput, awakened: Bool) async throws {
        if input.metadata.origin == .local {
            try input.context.validate()
            if case .text(let text) = input.payload, text.utf8.count > 16_384 {
                throw CommunicationError.invalidPayload
            }
        }
        let recognition = input.payload.speechRecognition
        if let recognition, input.sessionID == speechSessionID {
            guard recognition.kind == .final else { return }
            guard !input.metadata.expired else { throw CommunicationError.expired }
            if case .observation(let message) = input.payload { try input.validate(message) }
            if !awakened, input.turn != nil, !noteSpeechTerminal(input) { return }
        }
        let ordered: Bool
        if case .text = input.payload {
            ordered = true
        } else if recognition?.kind == .final {
            ordered = true
        } else if case .observation(let message) = input.payload,
            message.content(as: AgentTaskResponse.self) != nil
                || message.content(as: AgentTaskSignal.self).map({ AgentTaskMessaging.isPeer($0.scope.executor) })
                    == true
        {
            ordered = true
        } else {
            ordered = false
        }
        do {
            let serial = ordered && State.agentID == .assistant
            if serial { try await inputAdmission.acquire() }
            defer { if serial { inputAdmission.release() } }
            try await receiveSignal(input, awakened: awakened)
        } catch {
            if input.sessionID == speechSessionID, recognition?.kind == .final, let turn = input.turn {
                speechEnded(turn.id)
            }
            if (error as? CommunicationError) == .invalidPayload {
                ContainerInputMetrics.rejected(input, role: "ChatWorker")
            }
            if input.metadata.origin == .local || recognition?.kind == .final,
                (error as? CommunicationError) != .unauthorized,
                (error as? HarnessError) != .notRunning,
                descriptor.inputs.contains(input.payload.kind)
            {
                emit(.control("agent.error: input rejected: \(error)"), for: input)
            }
            throw error
        }
    }

    func receiveSignal(
        _ input: AgentInput, semantic: AssistantInputMessage? = nil, attachments: [ChatMessage] = [],
        awakened: Bool = false
    ) async throws {
        if case .observation(let message) = input.payload, message.contract == AssistantInterrupt.contract {
            guard State.agentID == .assistant,
                input.metadata.origin == .agent
                    || (input.metadata.origin == .local && input.metadata.source == "runtime"),
                input.metadata.origin == .local
                    || communicationPolicy.subscriptions.contains(where: {
                        $0.protocol == AssistantInterrupt.contract
                            && $0.sources.contains(input.metadata.source)
                            && input.metadata.incarnation != nil && input.metadata.topic == $0.channel
                    }),
                let signal = message.content(as: AssistantInterrupt.self)
            else { throw CommunicationError.unauthorized }
            guard !input.metadata.expired else { throw CommunicationError.expired }
            guard input.metadata.contract == AssistantInterrupt.contract, input.metadata.version == 1 else {
                throw CommunicationError.invalidPayload
            }
            try input.validate(message)
            let result = try await requestInterrupt(signal, sessionID: input.sessionID, source: input.metadata.source)
            try await prepareSignal(input)
            emit(.control("assistant.interrupt: \(result.rawValue)"), for: input)
            return
        }
        if case .observation(let message) = input.payload, message.contract == SpeechActivity.contract {
            guard State.agentID == .assistant, input.metadata.origin == .agent,
                input.metadata.incarnation != nil,
                communicationPolicy.subscriptions.contains(where: {
                    $0.protocol == SpeechActivity.contract
                        && $0.sources.contains(input.metadata.source) && input.metadata.topic == $0.channel
                }),
                let activity = message.content(as: SpeechActivity.self)
            else { throw CommunicationError.unauthorized }
            guard !input.metadata.expired else { throw CommunicationError.expired }
            guard input.metadata.contract == SpeechActivity.contract, input.metadata.version == 1 else {
                throw CommunicationError.invalidPayload
            }
            try input.validate(message)
            try receiveSpeechActivity(input, activity)
            return
        }
        if case .observation(let message) = input.payload, message.contract == SpeechKeywordMatch.contract {
            guard State.agentID == .assistant, input.metadata.origin == .agent, input.metadata.incarnation != nil,
                communicationPolicy.subscriptions.contains(where: {
                    $0.protocol == SpeechKeywordMatch.contract
                        && $0.sources.contains(input.metadata.source) && input.metadata.topic == $0.channel
                }),
                let match = message.content(as: SpeechKeywordMatch.self)
            else { throw CommunicationError.unauthorized }
            guard !input.metadata.expired else { throw CommunicationError.expired }
            guard input.metadata.contract == SpeechKeywordMatch.contract, input.metadata.version == 1,
                input.turn?.id == match.utterance
            else { throw CommunicationError.invalidPayload }
            try input.validate(message)
            try await receiveSpeechKeyword(input, match)
            return
        }
        if let recognition = input.payload.speechRecognition, recognition.kind == .final,
            input.sessionID == speechSessionID
        {
            guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
            if recognition.text.isEmpty {
                if let failure = recognition.failure {
                    emit(.control("agent.error: speech recognition: \(failure)"), for: input)
                }
                if let turn = input.turn { speechEnded(turn.id) }
                return
            }
            if !awakened, let listening, !listening.isListening {
                if let turn = input.turn { speechEnded(turn.id) }
                listening.receiveQuiet(recognition.text, input)
                return
            }
        }
        let arrivedAt = ContinuousClock.now
        let turnAtArrival = executionCancellationBarrier ? nil : decisionTurn
        let replyAtArrival = turnAtArrival != nil && hasReplyWork(sessionID: input.sessionID)
        let playbackAtArrival =
            inputDecision == nil || turnAtArrival == nil
            ? nil : await speechOutput?.isPlaying(sessionID: input.sessionID)
        if case .observation(let message) = input.payload, message.contract == ContainerFailureEvent.contract {
            throw CommunicationError.unauthorized
        }

        if State.isContextObservation(input) {
            guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
            try await contextRepository.update { try $0.state.applyContextObservation(input) }
            return
        }
        if case .observation(let message) = input.payload,
            let report = message.content(as: AgentTaskResponse.self)
        {
            guard try await receiveTaskReport(report, input: input) else { return }
            if let signal = report.signal, signal.kind == .result {
                await stopTrackingTask(signal.scope.id)
            } else if let rejection = report.rejection,
                let record = try await communications?.agentMessage(rejection.messageID), record.replyTo == nil
            {
                await stopTrackingTask(record.id)
            }
            return
        }
        if case .observation(let message) = input.payload,
            let signal = message.content(as: AgentTaskSignal.self)
        {
            guard
                input.metadata.origin == .runtime || !AgentTaskMessaging.isPeer(signal.scope.executor)
                    || (signal.kind != .progress && signal.kind != .result)
            else { throw CommunicationError.unauthorized }
            try await receiveTask(signal, input: input)
            if signal.kind == .result { await stopTrackingTask(signal.scope.id) }
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
        if case .executionFeedback(.actionFinished(let result)) = input.payload {
            try await acceptActionTerminal(result, input: input)
            return
        }
        if case .toolResult(let result) = input.payload {
            try await acceptToolFeedback(result, input: input)
            return
        }
        if try await acceptPendingFeedback(input) { return }
        if case .executionFeedback(let feedback) = input.payload,
            try await acceptExecutionLifecycle(feedback, input: input)
        {
            return
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
                if closesSession {
                    if decisionTurn?.sessionID == input.sessionID { decisionTurn = nil }
                    peerNotices.removeAll { $0.input.sessionID == input.sessionID }
                    if input.sessionID == speechSessionID {
                        cancelInterruptionWait()
                        clearSpeechUtterances()
                    }
                }
                guard !hostCancellationInProgress else { throw HarnessError.invalidTransition }
                hostCancellationInProgress = true
                hostCancellationSession = input.sessionID
                cancelledAdmissions.formUnion(
                    admittingInputs.keys.filter {
                        admittingInputs[$0] == input.sessionID
                            && (!preservingInterruptionSpeechAdmissions || !admittingSpeechFinals.contains($0))
                    })
                defer {
                    hostCancellationInProgress = false
                    hostCancellationSession = nil
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
                let cancelledSpeech = oldIDs.union(activeInterruption.map { [$0.replyInputID] } ?? [])
                for id in cancelledSpeech {
                    await speechOutput?.cancel(
                        input: AgentInput(id: id, sessionID: input.sessionID, payload: .text("")))
                }
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
                let cancelledQueued = queue.inputs.filter { candidate in
                    closesSession && candidate.sessionID == input.sessionID && candidate.id != cancelledActive?.id
                        && !pendingRounds.values.contains(where: { $0.input.id == candidate.id })
                }
                if closesSession { await decisionQueue.remove(sessionID: input.sessionID) }
                let cancelledInputs = cancelledQueued
                try await prepareSignal(input)
                for pending in cancelledInputs {
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
                for pending in cancelledInputs {
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
                try await contextRepository.update { context in
                    let inputs = Set(
                        context.work.filter {
                            $0.value.sessionID == input.sessionID && (closesSession || oldIDs.contains($0.key))
                        }.map(\.key))
                    if closesSession {
                        try context.state.skillState?.closeSession(input.sessionID, inputs: inputs)
                    } else {
                        try context.state.skillState?.interruptSession(input.sessionID, inputs: inputs)
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
                }
                if reportHostCancellationFailure { throw HarnessError.queueFull }
            }
            return
        }
        if case .observation(let observation) = input.payload {
            guard case .transcript(_, final: true)? = observation.perception else {
                throw HarnessError.unsupportedInput
            }
            _ = try observation.validatedSize()
        }
        let isUser = semantic == nil && AssistantInputMessage.isUser(input)
        if isUser {
            let views = try await interactionViews(sessionID: input.sessionID)
            if !views.isEmpty {
                guard inputInteractions[input.id] != nil || inputInteractions.count < capacity + 1 else {
                    throw CommunicationError.capacityExceeded
                }
                inputInteractions[input.id] = views
            }
        }
        let trackedSpeechFinal = isTrackedSpeechFinal(input)
        guard
            hostCancellationSession != input.sessionID
                || (preservingInterruptionSpeechAdmissions && trackedSpeechFinal)
        else { throw HarnessError.invalidTransition }
        let ordinary = queue.inputs.filter { pending in
            !fullDuplex
                || (continuationRounds[pending.id] == nil
                    && !pendingRounds.values.contains { $0.input.id == pending.id })
        }
        let waitingMembers = ordinary.flatMap { batchMembers[$0.id] ?? [$0] }
        guard waitingMembers.count + admitting < capacity else {
            throw HarnessError.queueFull
        }
        if fullDuplex {
            let live = try await contextRepository.snapshot().work.values.filter { !$0.state.terminal }
            guard live.count + admitting < 64 else { throw HarnessError.queueFull }
            let queued = waitingMembers
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
        if trackedSpeechFinal { admittingSpeechFinals.insert(input.id) }
        defer {
            admitting -= 1
            admittingInputs[input.id] = nil
            admittingSpeechFinals.remove(input.id)
            cancelledAdmissions.remove(input.id)
            if settlementAdmissions.contains(input.id) { drain() }
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
                _ = try await conversations.admitUserInput(id: input.id, user: userText, model: "Not started")
                if fullDuplex {
                    var evidence = AssistantInputCoordination(
                        source: input.metadata.source, capturedAt: String(input.metadata.capturedAt))
                    attachSpeechInterruption(to: input, evidence: &evidence)
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
        guard !cancelledAdmissions.contains(input.id),
            hostCancellationSession != input.sessionID
                || (preservingInterruptionSpeechAdmissions && trackedSpeechFinal)
        else {
            inputInteractions[input.id] = nil
            try await contextRepository.update { context in
                if context.work[input.id]?.state.terminal == false {
                    try context.transitionWork(input.id, to: .cancelled)
                }
            }
            throw CancellationError()
        }
        // Freeze context and target before enqueue can trigger this input's own reply.
        let occupied = replyAtArrival || playbackAtArrival == true
        let turn = occupied ? turnAtArrival.flatMap { $0.sessionID == input.sessionID ? $0 : nil } : nil
        let keywordInterrupted = hasKeywordInterruption(for: input)
        // Idle input skips interruption Decision and uses ordinary queue admission.
        let snapshot = (turn != nil && !keywordInterrupted && !awakened ? userText : nil).map { text in
            InputDecisionSnapshot(
                input: input, text: text,
                currentAssistantReply: turn?.assistant ?? "", receivedAt: arrivedAt)
        }
        try queue.admit(input, disposition: .enqueue(priority: 0))
        admitted = true
        if isUser { blockedSessions.remove(input.sessionID) }
        if isUser { replyInputs.insert(input.id) }
        if isUser, let inputDecision, let snapshot, let target = turn?.id,
            canRunInterruptDecision(target: target, sessionID: input.sessionID)
        {
            do {
                try await decisionQueue.submit(
                    .init(
                        snapshot: snapshot, target: target,
                        interrupt: { [weak self] signal, session, route in
                            guard let self else { throw CommunicationError.unavailableTarget }
                            return try await self.admitInterrupt(
                                signal, sessionID: session, source: "decision", keyword: nil,
                                cause: .init(
                                    inputID: input.id, source: input.metadata.source,
                                    capturedAt: String(input.metadata.capturedAt), route: route.rawValue))
                        },
                        complete: { [weak self] snapshot, result, duration in
                            await self?.completeInputDecision(snapshot, outcome: result, duration: duration)
                        }, updated: { [weak self] in await self?.publishInputQueue() },
                        canClassify: { [weak self] in
                            await self?.canRunInterruptDecision(target: target, sessionID: input.sessionID) ?? false
                        }), using: inputDecision)
            } catch {
                let failure = InputDecisionOutcome(
                    route: .failed, modelResult: nil,
                    signalStatus: "decision_failed",
                    reason: "Decision admission failed; input remains queued: \(error)",
                    requests: [], failure: .model)
                emit(.control("decision.error: \(error)"), for: input)
                await decisionLog?(snapshot, failure, .zero)
            }
        }
        if fullDuplex { await publishInputQueue() }
        if input.sessionID == speechSessionID, case .transcript(_, final: true)? = input.payload.perception,
            let turn = input.turn
        {
            speechEnded(turn.id)
        }
        if lifecycle == .running { drain() }
    }

    func receiveSpeechKeyword(_ input: AgentInput, _ match: SpeechKeywordMatch) async throws {
        guard input.sessionID == speechSessionID, fullDuplex, listening?.isListening != false,
            interruptionKeywordLabels.contains(match.label), let reply = decisionTurn,
            match.onset >= reply.startedAt
        else { return }
        _ = try await admitInterrupt(
            .init(target: .reply(reply.id)), sessionID: input.sessionID, source: "keyword",
            keyword: (input, match),
            cause: .init(
                inputID: input.id, source: input.metadata.source,
                capturedAt: String(input.metadata.capturedAt), route: DecisionLogItem.Route.keyword.rawValue))
    }

    func interactionViews(sessionID: String) async throws -> [AgentTaskView] {
        let foreground = foregroundInteraction
        let views = try await contextRepository.snapshot().state.taskViews ?? [:]
        return views.values.filter {
            !$0.terminal && $0.scope.sessionID == sessionID && $0.stage == .waitingUser
                && ($0.scope.id == foreground || AgentTaskMessaging.isPeer($0.scope.executor))
        }
    }

    func handleText(_ incomingText: String, input: AgentInput) -> Bool {
        let text = batchTexts[input.id] ?? incomingText
        activeInput = input
        beginDecisionTurn(input)
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
                    try await finishLocalDecision(input: input, finishRequested: false)
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
    func makeSemanticMessage(
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
    func retainPreparedBatch(_ input: AgentInput, error: any Error) async throws -> Bool {
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

    static func inputText(_ input: AgentInput) -> String? {
        switch input.payload {
        case .text(let text): return text
        case .observation(let message):
            if case .transcript(let text, final: true)? = message.perception { return text }
            return nil
        default: return nil
        }
    }
    func drain() {
        guard worker == nil, lifecycle == .running, !hostCancellationInProgress else { return }
        if let index = readyRoundSettlements.firstIndex(where: { id in
            guard let pending = pendingRounds[id], !pending.publishing else { return false }
            return !executionCancellationBarrier || pending.cancelled
        }), let pending = pendingRounds[readyRoundSettlements[index]] {
            let id = readyRoundSettlements.remove(at: index)
            pendingRounds[id]?.settling = true
            let input = pending.input
            // Finish admissions already in flight for the same batch before selecting the next model input.
            settlementAdmissions.formUnion(admittingInputs.filter { $0.value == input.sessionID }.keys)
            processed += 1
            activeInput = input
            beginDecisionTurn(input)
            worker = Task { await self.generate(pending.text, input: input, using: pending.chat, settlingRoundID: id) }
            return
        }
        guard !executionCancellationBarrier, pendingRounds.isEmpty else { return }
        settlementAdmissions.formIntersection(Set(admittingInputs.keys))
        guard settlementAdmissions.isEmpty else { return }
        while lifecycle == .running && !queue.isEmpty {
            var excluded = Set(
                queue.inputs.filter { queued in
                    blockedSessions.contains(queued.sessionID)
                        || (queued.sessionID == speechSessionID && interruptionWait != nil)
                }.map(\.id))
            let ordinarySpeech = queue.inputs.filter {
                $0.sessionID == speechSessionID && !excluded.contains($0.id)
            }
            let laterSpeech: Set<String>
            if ordinarySpeech.contains(where: { !isAfterSpeechWindow($0) }) {
                laterSpeech = Set(ordinarySpeech.filter { isAfterSpeechWindow($0) }.map(\.id))
                excluded.formUnion(laterSpeech)
            } else {
                laterSpeech = []
            }
            guard let entry = queue.take(excluding: excluded) else { return }
            let input = entry.input
            processed += 1
            if fullDuplex, Self.inputText(input) != nil {
                let excluded = Set(queue.inputs.filter { Self.inputText($0) == nil }.map(\.id)).union(laterSpeech)
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
                    let text = try AssistantInputBatch(
                        messages: values, interruptedIntentions: interruptedIntents[input.sessionID]
                    ).text()
                    batchTexts[input.id] = text
                    if handleText(text, input: input) {
                        if input.sessionID == speechSessionID { interruptionBatchStartedAt = nil }
                        return
                    }
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
                default: break
                }
            // Unsupported input is rejected by the descriptor; receipts are handled before this switch.
            case .image, .audio, .actionResult, .executionFeedback, .activityEvent, .event: break
            case .toolResult(let result):
                activeInput = input
                beginDecisionTurn(input)
                worker = Task { await self.emitImmediate(result.value, for: input) }
                return
            }
        }
        if lifecycle == .running,
            let index = peerNotices.firstIndex(where: {
                interruptionWait == nil || $0.input.sessionID != speechSessionID
            })
        {
            let notice = peerNotices.remove(at: index)
            activePeerTaskNoticeID = notice.input.id
            activeInput = notice.input
            worker = Task { await playPeerTaskNotice(notice) }
        }
    }
    func beginReplyTurn(_ input: AgentInput) throws {
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
}
