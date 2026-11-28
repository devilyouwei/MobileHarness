import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

/// Metadata-only UI projection. Exact capability requests and native pairs are retained in modelRequests.
public enum ConversationContextBuilder {
    public static func request(system: String, user: String, conversation: AssistantConversation) throws
        -> [ModelMessage]
    {
        try AssistantContextState.buildChatMessages(system: system, user: user, conversation: conversation).compactMap {
            guard let role = ModelMessage.Role(rawValue: $0.role.rawValue) else { return nil }
            return ModelMessage(role: role, content: $0.content)
        }
    }
}

/// Live Agent state stays in memory; normalized SQLite rows are the durable business facts.
public enum AssistantConversationStorage {
    public static func store(
        repository: AgentContextRepository<AssistantContextState>, messages: any AssistantMessageRepository,
        tasks: any AssistantTaskRepository & AssistantTaskSummaryRepository,
        conversations: any AssistantConversationRepository, logs: any ModelRequestLogRepository
    ) throws
        -> AssistantHistoryStore
    {
        let records = try AssistantRecordStore(
            repository: messages, tasks: tasks, conversations: conversations, logs: logs)
        return AssistantHistoryStore(
            contextIdentity: repository.scopeID, records: records,
            canArchive: {
                guard try await repository.snapshot().state.skillState?.activeTaskID == nil else {
                    throw CommunicationError.scopeClosed
                }
            },
            restore: { history in
                try await repository.update { $0.state.history = history }
            },
            contextLoad: { try await repository.snapshot().state.history },
            contextCommit: { history in try await AssistantHistoryContext.commit(history, to: repository) })
    }
}

extension AssistantChatWorker {
    func captureDecisionText(_ text: String, input: AgentInput) {
        guard decisionTurn?.inputID == input.id else { return }
        decisionTurn?.assistant += text
    }
}

extension AssistantChatWorker {
    func beginHistoryRequest(input: AgentInput, text: String, messages: [ChatMessage]) async throws
        -> AssistantRecord
    {
        let name = try await modelName()
        if State.agentID == .assistant { try await inputAdmission.acquire() }
        defer { if State.agentID == .assistant { inputAdmission.release() } }
        let history = try await conversations.readCurrent()
        if fullDuplex, history.current.turns.contains(where: { $0.id == input.id }) {
            return try await conversations.prepareAdmittedInput(
                id: input.id, dialogID: history.current.id, user: Self.inputText(input) ?? text,
                request: AgentChatContextBuilder.project(messages), model: name)
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
}
