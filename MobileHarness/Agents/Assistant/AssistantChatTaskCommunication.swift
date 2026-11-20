import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    func communicate(
        _ message: AgentMessage, parent: AgentInput, to target: AgentID? = nil, originDialog: String? = nil
    ) async throws
        -> DeliveryReport
    {
        let signal = message.content(as: AgentTaskSignal.self)
        let action = try CommunicationAction(
            id: signal?.scope.execution == .background && target != nil && signal?.kind == .request
                ? signal?.scope.id : message.content(as: AgentTaskRequest.self)?.id,
            message: message, target: target)
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
        guard let messaging else { throw CommunicationError.unavailableTarget }
        let report: DeliveryReport
        if let target {
            let reference =
                message.content(as: AgentTaskRequest.self).map { $0.replyTo ?? $0.id }
                ?? signal.flatMap { [.request, .input, .cancel].contains($0.kind) ? $0.scope.id : nil }
            let created: Bool
            if let reference {
                created = try await trackTask(reference: reference, producer: target, sessionID: parent.sessionID)
                if trackedTasks[reference]?.originDialog == nil {
                    trackedTasks[reference]?.originDialog = originDialog
                }
            } else {
                created = false
            }
            do {
                if let reference {
                    guard let tracked = trackedTasks[reference],
                        hasStaticTaskSubscription(from: tracked.producer) || tracked.dynamicSubscription != nil
                    else { throw CancellationError() }
                }
                try Task.checkCancellation()
                report = try await messaging.sendResult(message, parent: parent, to: target)
            } catch {
                if created, let reference { await stopTrackingTask(reference) }
                throw error
            }
            if created, let reference, report.failure != nil || !report.rejected.isEmpty {
                await stopTrackingTask(reference)
            }
        } else {
            try await messaging.publish(message, parent: parent)
            report = DeliveryReport()
        }
        return report
    }

    public func ownsFeedback(_ input: AgentInput) -> Bool {
        switch input.payload {
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
        guard report.publicationAccepted == true, report.failure == nil else {
            throw CommunicationError.unavailableTarget
        }
    }

    func receiveTask(_ signal: AgentTaskSignal, input: AgentInput) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        if usesSkills && signal.scope.execution == .background && (signal.kind == .request || signal.kind == .input) {
            throw CommunicationError.unsupportedContract
        }
        let content: AgentTaskContent
        if signal.kind == .cancel || signal.businessContract == "runtime.taskTermination" {
            content = try AgentTaskContent(
                text: (try AgentPrompts.text("Shared/CommunicationContext", "stopped")),
                stage: signal.kind == .result ? .completed : .running)
        } else if signal.scope.execution == .background && signal.businessContract != AgentTaskContent.contract {
            guard signal.kind == .progress || signal.kind == .result else {
                throw CommunicationError.unsupportedContract
            }
            content = try AgentTaskContent(
                text: String(
                    (String(data: signal.data, encoding: .utf8)
                        ?? (try AgentPrompts.text(
                            "Shared/CommunicationContext", "opaqueEvidence", ["bytes": String(signal.data.count)])))
                        .prefix(1024)),
                stage: signal.kind == .result ? .completed : .running)
        } else {
            content = try AgentTaskContent.decode(signal)
        }
        if AgentTaskMessaging.isPeer(signal.scope.executor), signal.scope.execution == .background,
            signal.kind == .result,
            signal.businessContract == "runtime.taskTermination"
        {
            // The Writer persists and reports its own terminal outcome independently of the grant.
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
                result: ToolResult(
                    callID: input.id, value: (try AgentPrompts.text("Shared/CommunicationContext", "cancelled")),
                    isError: true), status: .cancelled)
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

    func messageScopeForReport(_ report: AgentTaskResponse, input: AgentInput) -> String? {
        guard case .observation(let message) = input.payload else { return nil }
        if let signal = report.signal { return message.eventScope == signal.scope.id ? signal.scope.id : nil }
        return message.eventScope
    }

    @discardableResult
    func receiveTaskReport(_ report: AgentTaskResponse, input: AgentInput) async throws -> Bool {
        guard lifecycle == .running || lifecycle == .paused, State.agentID == .assistant,
            input.metadata.origin == .agent, AgentTaskMessaging.isPeer(AgentID(rawValue: input.metadata.source)),
            input.metadata.incarnation != nil
        else { throw CommunicationError.unauthorized }
        try report.validate()
        guard let reference = messageScopeForReport(report, input: input) else {
            throw CommunicationError.invalidPayload
        }
        await recordReceived(report, reference: reference, input: input)
        guard let tracked = trackedTasks[reference], tracked.producer == AgentID(rawValue: input.metadata.source),
            tracked.sessionID == input.sessionID
        else { return false }
        if let rejection = report.rejection {
            guard rejection.sessionID == input.sessionID else { throw CommunicationError.unauthorized }
            try await receiveTaskMessageRejection(rejection, reference: reference, input: input)
            if rejection.messageID == reference { await stopTrackingTask(reference) }
            return true
        }
        guard let signal = report.signal, signal.scope.requester == descriptor.id,
            signal.scope.executor.rawValue == input.metadata.source,
            signal.scope.sessionID == input.sessionID
        else { throw CommunicationError.unauthorized }
        let content = try AgentTaskContent.decode(signal)
        guard let event = content.event else { throw CommunicationError.invalidPayload }
        if signal.kind == .result {
            try await receivePeerCompletion(signal: signal, content: content, event: event, input: input)
            await stopTrackingTask(reference)
        } else {
            try await receivePeerEvent(signal, content: content, event: event, input: input)
        }
        return true
    }

    /// Only called after the owning task's identity and sequence have been validated.
    func admitPeerText(_ text: String, input: AgentInput, scope: AgentTaskScope? = nil) async throws {
        let candidate = AgentInput(
            id: input.id + ".semantic", sessionID: input.sessionID,
            payload: .text(text), metadata: input.metadata, turn: input.turn, taskScope: scope)
        let semantic = try makeSemanticMessage(
            input: candidate, role: .agent, channel: "agent." + input.metadata.source, content: text)
        try await receiveSignal(candidate, semantic: semantic)
    }

    func activateNextInteraction(parent: AgentInput) async throws {
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

    func completeTaskDecision(_ input: AgentInput) async throws {
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
                value: String(
                    (turn?.raw ?? (try AgentPrompts.text("Shared/CommunicationContext", "completed"))).prefix(1024))))
    }

    func requireTaskSignal(_ input: AgentInput) throws -> AgentTaskSignal {
        guard case .observation(let message) = input.payload,
            let signal = message.content(as: AgentTaskSignal.self)
        else { throw CommunicationError.invalidPayload }
        return signal
    }

    func releaseDelegations(parent: AgentInput) async throws {
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

    func forwardDirectedInput(_ intent: AgentTaskInputIntent, input: AgentInput) async throws {
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
                if AgentTaskMessaging.permits(
                    target: view.scope.executor, requester: descriptor.id, communication: communicationPolicy)
                {
                    let content = AgentTaskRequest(
                        text: intent.text, replyTo: view.scope.id, interactionID: intent.interactionID)
                    try await deliverTaskMessage(content, to: view.scope.executor, parent: input)
                    return
                }
                let report = try await communicate(signal.message(), parent: input, to: view.scope.executor)
                guard report.delivered.contains(view.scope.executor), report.rejected.isEmpty else {
                    throw CommunicationError.unavailableTarget
                }
                if foregroundInteraction == view.scope.id {
                    pendingInteractions.removeAll { $0 == view.scope.id }
                    foregroundInteraction = nil
                    try await activateNextInteraction(parent: input)
                }
            } catch { emit(.control("agent.inputRejected: \(error)"), for: input) }
        }
    }

    func sendTaskMessage(
        arguments: [String: String], parent: AgentInput?, sessionID: String, inputID: String
    ) async throws {
        guard Set(arguments.keys) == ["agent_id", "text"], let targetID = arguments["agent_id"],
            let text = arguments["text"]
        else { throw CommunicationError.invalidPayload }
        let target = AgentID(rawValue: targetID)
        guard
            AgentTaskMessaging.permits(target: target, requester: descriptor.id, communication: communicationPolicy)
        else { throw CommunicationError.invalidPayload }
        let question = inputInteractions[inputID]?.first { $0.scope.executor == target }
        let content = AgentTaskRequest(
            text: text, replyTo: question?.scope.id, interactionID: question?.interactionID)
        try await deliverTaskMessage(
            content, to: target,
            parent: parent ?? AgentInput(id: inputID, sessionID: sessionID, payload: .text(text)))
    }

    /// The sender only sends by protocol and waits for the delivery reply; the receiver records the message.
    func deliverTaskMessage(_ content: AgentTaskRequest, to target: AgentID, parent: AgentInput) async throws {
        let dialog = try await contextRepository.snapshot().state.history.current.id
        let message = AgentTaskRequest(
            id: content.id, text: content.text, replyTo: content.replyTo, interactionID: content.interactionID,
            operation: content.operation, senderContext: dialog)
        let report = try await communicate(message.message, parent: parent, to: target, originDialog: dialog)
        guard report.failure == nil, report.rejected.isEmpty, report.delivered.contains(target) else {
            throw CapabilityError.unavailable(report.rejected[target] ?? report.failure ?? "Message unavailable")
        }
    }

    func receiveTaskMessageRejection(
        _ rejection: AgentTaskResponse.Rejection, reference: String, input: AgentInput
    ) async throws {
        guard let origin = trackedTasks[reference]?.originDialog,
            origin == (try await contextRepository.snapshot()).state.history.current.id
        else { return }
        let notice = AgentInput(
            id: rejection.eventID, sessionID: input.sessionID, payload: input.payload, metadata: input.metadata)
        if fullDuplex {
            try await admitPeerText(rejection.text, input: notice)
            return
        }
        try await recordPeerTurn(id: rejection.eventID, text: rejection.text, originDialog: origin)
        if presentsReply {
            enqueuePeerTaskNotice(
                .init(
                    input: notice, scopeID: rejection.messageID, originDialog: origin, kind: nil, interactionID: nil,
                    text: try Self.peerNoticeText(rejection.text, from: AgentID(rawValue: input.metadata.source))))
        }
    }
}
