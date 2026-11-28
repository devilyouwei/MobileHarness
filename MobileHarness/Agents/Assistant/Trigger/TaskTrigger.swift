import AgentCore
import Foundation
import StorageChat
import StorageCore
import StorageTasks

extension AssistantChatWorker {
    /// The `task` trigger handler: the goal record owns the value, so nothing is published afterwards.
    func taskTrigger(_ write: AgentStateWrite) async throws -> AgentStateTriggerOutcome {
        let schema = try AgentConfigurations.stateSchema(named: State.configurationName)
        try await writeTask(
            setting: write.new != nil, name: write.name, value: write.new, note: write.note, source: write.source,
            schema: schema, sessionID: write.sessionID, inputID: write.inputID, decisionID: write.decisionID)
        return .handled
    }

    /// The `task` trigger: setting opens a goal interval, clearing (or replacing) closes it with a summary and compresses
    /// the history it covered. The goal record is the single owner of the value.
    private func writeTask(
        setting: Bool, name: String, value: String?, note: String?, source: AgentStateSource,
        schema: AgentStateSchema, sessionID: String, inputID: String, decisionID: String?
    ) async throws {
        try AgentStateVariables.checkWritable(name, source: source, schema: schema)
        let goal = try setting ? AgentStateVariables.normalized(name, value ?? "", source: source, schema: schema) : nil
        let hasActive = try await contextRepository.snapshot().state.skillState?.activeTaskID != nil
        let immediate = fullDuplex || decisionID == nil
        if hasActive {
            guard let note else { throw AgentStateError.noteRequired(name) }
            guard !setting || immediate else { throw AgentStateError.replacementUnavailable(name) }
            if immediate {
                try await completeForegroundTask(summary: note, inputID: inputID, requestID: decisionID)
            } else {
                try await requestForegroundFinish(summary: note, inputID: inputID)
            }
        } else if !setting {
            return
        }
        if let goal {
            try await beginForegroundTask(goal: goal, sessionID: sessionID, inputID: inputID, decisionID: decisionID)
        }
    }

    private func beginForegroundTask(goal: String, sessionID: String, inputID: String, decisionID: String?)
        async throws
    {
        guard var preview = try await contextRepository.snapshot().state.skillState else {
            throw CommunicationError.invalidPayload
        }
        // Validate against a copy before any record is created.
        try preview.beginTask(goal: goal, taskID: "task_1", sessionID: sessionID, inputID: inputID)
        guard let taskRecords else { throw RecordStorageError.missingRecord }
        let dialog = try await conversations.readCurrent().current.id
        let taskID = try await taskRecords.createTask(
            dialog: BusinessRecordID(rawValue: dialog)?.kind == .dialog ? dialog : nil,
            agent: descriptor.id.rawValue, goal: goal)
        do {
            try await contextRepository.transaction { context in
                guard var skills = context.state.skillState else { throw CommunicationError.invalidPayload }
                try skills.beginTask(goal: goal, taskID: taskID, sessionID: sessionID, inputID: inputID)
                if let decisionID {
                    try context.state.history.assignHistoryTask(taskID, inputID: inputID, requestID: decisionID)
                }
                context.state.skillState = skills
                context.state.reconcileTaskCompressions()
            }
        } catch {
            try await taskRecords.endTask(taskID, status: "failed", failure: String(describing: error))
            throw error
        }
        if let committed = try await contextRepository.snapshot().state.skillState {
            skillContinuation.yield(committed)
        }
        try await conversations.checkpoint(inputID: inputID)
    }

    /// Non-duplex model-driven end: the interval is marked finishing and settles when its decision joins.
    private func requestForegroundFinish(summary: String, inputID: String) async throws {
        try await contextRepository.transaction { context in
            guard var skills = context.state.skillState else { throw CommunicationError.invalidPayload }
            try skills.requestFinish(summary: summary)
            context.state.skillState = skills
        }
        if let committed = try await contextRepository.snapshot().state.skillState {
            skillContinuation.yield(committed)
        }
        try await conversations.checkpoint(inputID: inputID)
    }

    func completeForegroundTask(summary: String, inputID: String, requestID: String?) async throws {
        guard var skills = try await contextRepository.snapshot().state.skillState,
            let task = skills.tasks.first(where: { $0.id == skills.activeTaskID }),
            requestID == nil || skills.taskID(for: inputID) == task.id
        else { throw CommunicationError.scopeClosed }
        try skills.requestFinish(summary: summary)
        let finishedAt = Date()
        try await conversations.completeForegroundTask(
            task.id, goal: task.goal, summary: summary, finishedAt: finishedAt, inputID: inputID, requestID: requestID
        ) { [contextRepository] archive, persist in
            try await contextRepository.transaction(beforePublishing: persist) { context in
                guard var skills = context.state.skillState, skills.activeTaskID == task.id,
                    context.state.history.revision == archive.revision - 1
                else { throw CommunicationError.scopeClosed }
                try skills.requestFinish(summary: summary)
                try skills.settleTask(finishedAt: finishedAt)
                context.state.skillState = skills
                context.state.history = archive
            }
        }
        if let skills = try await contextRepository.snapshot().state.skillState { skillContinuation.yield(skills) }
    }
}
