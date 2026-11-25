import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        try await AssistantHistoryContext.attach(repository: contextRepository, store: conversations)
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
    func startUIInputs() async throws {
        guard let uiHome, let uiSessionID else { return }
        let source = await uiHome.requests
        let task = try await consumeUI(source, sessionID: uiSessionID) { agent, value, context in
            switch value {
            case .text(let text): try await agent.handleUIText(text, context: context)
            }
        }
        uiInputs.append(task)
    }
    func stopUIInputs() async { await uiInputs.retire(for: descriptor.id)() }
    func handleUIText(_ text: String, context: ProcessingContext) async throws {
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
        cancelInterruptionWait()
        clearSpeechUtterances()
        var cancellationFailure: (any Error)?
        if State.acceptsDirectedUserInput {
            do {
                let views = (try await contextRepository.snapshot()).state.taskViews ?? [:]
                for view in views.values
                where !view.terminal && view.stage == .running && !AgentTaskMessaging.isPeer(view.scope.executor) {
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
        await decisionQueue.cancelAndWait()
        let parked = pendingRounds
        var seen: Set<String> = []
        let pending =
            (queue.inputs
            + parked.values.map(\.input)
            + batchMembers.values.flatMap { $0 }).filter {
                $0.id != current?.id && seen.insert($0.id).inserted
            }
        decisionTurn = nil
        pendingRounds.removeAll()
        settlementAdmissions.removeAll()
        batchMembers.removeAll()
        batchTexts.removeAll()
        mergedResults.removeAll()
        coordination.removeAll()
        interruptedInputs.removeAll()
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
        try await contextRepository.update {
            try $0.state.skillState?.interruptSession()
            $0.state.reconcileTaskCompressions()
        }
        if let skills = try await contextRepository.snapshot().state.skillState { skillContinuation.yield(skills) }
        await publishInputQueue()
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
        listening?.cancelJudgment()
        cancelInterruptionWait()
        clearSpeechUtterances()
        for reference in Array(trackedTasks.keys) { await stopTrackingTask(reference) }
        await decisionQueue.cancelAndWait()
        await inputDecision?.stop()
        decisionTurn = nil

        await stopUIInputs()
        lifecycle = .stopped
        peerNotices.removeAll()
        var seen: Set<String> = []
        let queued =
            (queue.inputs + pendingRounds.values.map(\.input) + batchMembers.values.flatMap { $0 }).filter {
                seen.insert($0.id).inserted && $0.id != activeInput?.id
            }
        pendingRounds.removeAll()
        settlementAdmissions.removeAll()
        batchMembers.removeAll()
        batchTexts.removeAll()
        mergedResults.removeAll()
        coordination.removeAll()
        interruptedInputs.removeAll()
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
        messaging = nil
        for task in routingWorkers.values { await task.value }
        routingWorkers.removeAll()
        await speechOutput?.stop()
        await worker?.value
        replyInputs.removeAll()
        await publishInputQueue()
        do { try await conversations.checkpoint() } catch {
            if let input = activeInput ?? queued.last {
                emit(.control("agent.historyError: \(error)"), for: input)
            } else {
                Logger(subsystem: "dev.mobileharness", category: "AssistantHistory").error(
                    "History checkpoint failed: \(String(describing: error), privacy: .private)")
            }
        }
        stateContext?.close()
        continuation.finish()
        skillContinuation.finish()
    }
}
