import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    func prepareSignal(_ input: AgentInput) async throws {
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
                if input.payload.kind == .text || AssistantInputMessage.isUser(input) {
                    try skills.bind(input.id, task: skills.activeTaskID)
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

    func captureDecisionText(_ text: String, input: AgentInput) {
        guard decisionTurn?.inputID == input.id else { return }
        decisionTurn?.assistant += text
    }

    func hasReplyWork(sessionID: String) -> Bool {
        activeInput?.sessionID == sessionID
            || pendingRounds.values.contains { $0.input.sessionID == sessionID && !$0.cancelled }
    }

    func hasActiveReply(sessionID: String) async -> Bool {
        guard lifecycle == .running else { return false }
        if hasReplyWork(sessionID: sessionID) { return true }
        let playing = await speechOutput?.isPlaying(sessionID: sessionID)
        return lifecycle == .running && (hasReplyWork(sessionID: sessionID) || playing == true)
    }

    func speechEndpointActivity(acknowledging id: UUID?) async -> (replyActive: Bool, interruptionID: UUID?) {
        if let id, id == speechInterruptionID { speechInterruptionID = nil }
        guard let speechSessionID, lifecycle == .running else { return (false, nil) }
        let active = await hasActiveReply(sessionID: speechSessionID)
        return (active, speechInterruptionID)
    }

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: queue.count, processedInputs: processed)
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

    func beginHistoryRequest(input: AgentInput, text: String, messages: [ChatMessage]) async throws
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

    func finishLocalDecision(
        input: AgentInput, finishRequested: Bool = true, interrupted: Bool = false, taskBoundaryOnly: Bool = false
    ) async throws {
        guard usesSkills else { return }
        let completed = try await contextRepository.transaction { context -> AgentTaskSkillState.TaskRecord? in
            guard var skills = context.state.skillState,
                skills.activeTaskID == nil || skills.taskID(for: input.id) == skills.activeTaskID
            else {
                context.state.skillState?.discardDecision(input.id)
                return nil
            }
            let activeTaskID = skills.activeTaskID
            if interrupted {
                try skills.settleTask(finishRequested: false)
                skills.discardDecision(input.id)
            } else if taskBoundaryOnly {
                try skills.settleTask()
            } else {
                try skills.decisionCompleted(inputID: input.id, finishRequested: finishRequested)
            }
            context.state.skillState = skills
            context.state.reconcileTaskCompressions()
            return skills.tasks.first { $0.id == activeTaskID && $0.status == "completed" }
        }
        if let completed {
            try await taskRecords?.endTask(
                completed.id, status: "completed", failure: nil, finishedAt: completed.updatedAt ?? Date())
        }
        if let skills = try await contextRepository.snapshot().state.skillState {
            skillContinuation.yield(skills)
        }
    }
    func decisionMetadata(skills: AgentTaskSkillState?, states: [String]? = nil)
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
            "controls": registry.controls.map {
                [
                    "path": $0.path.description, "alias": $0.alias, "destination": $0.destination.rawValue,
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
