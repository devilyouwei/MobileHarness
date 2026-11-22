import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import Synchronization
import UI

/// Late-bound entry to the Assistant's control path for host callers that are built before the Assistant exists.
final class AssistantControlLink: Sendable {
    private let agent = Mutex<AssistantAgent?>(nil)
    func bind(_ value: AssistantAgent?) { agent.withLock { $0 = value } }

    func speechPublicationFailed(_ input: AgentInput, reason: String) async {
        guard let assistant = agent.withLock({ $0 }) else { return }
        await assistant.speechPublicationFailed(input, reason: reason)
    }

    /// The host clears the foreground goal (`task`) with a summary; it is a host write, not a model call.
    func clearForegroundTask(summary: String, sessionID: String) async throws {
        guard let assistant = agent.withLock({ $0 }) else { throw CommunicationError.unavailableTarget }
        _ = try await assistant.control(
            .stateClear, arguments: ["name": "task", "note": summary], source: AgentID.assistant.rawValue,
            sessionID: sessionID, inputID: UUID().uuidString, decisionID: nil)
    }
}

extension AssistantChatWorker {
    /// Runs a control owned by the Assistant; it never reaches the Actions Shell.
    func executeControl(path: String, arguments: [String: String], input: AgentInput, callID: String)
        async throws -> ToolResult
    {
        guard let control = try AssistantControls.control(path: path) else { throw HarnessError.forbiddenFunction }
        do {
            let completion = try await self.control(
                control.operation, arguments: arguments, source: descriptor.id.rawValue,
                sessionID: input.sessionID, inputID: input.id, decisionID: roundID)
            return ToolResult(
                callID: callID, value: try Self.completionText(completion.agentValue),
                completion: completion.agentValue)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            return ToolResult(
                callID: callID, value: String(describing: error), isError: true, failureCode: "controlFailed")
        }
    }

    /// Success of `state.set`, `state.clear` and `send` carries no value; every failure throws. `state.get` and the
    /// Skill controls return a value. A thrown error or a value continues the decision.
    public func control(
        _ operation: AgentControlOperation, arguments: [String: String], source: String, sessionID: String,
        inputID: String, decisionID: String?
    ) async throws -> ActionCompletion {
        guard usesSkills, source == descriptor.id.rawValue, lifecycle == .running else {
            throw CommunicationError.unauthorized
        }
        let fixed = decisionID == nil
        let parked = decisionID.flatMap { pendingRounds[$0] }
        let controlInput = parked?.input ?? activeInput
        guard parked?.cancelled != true else { throw CommunicationError.scopeClosed }
        if fixed {
            let idleForControl = (activeInput == nil && worker == nil) || activePeerTaskNoticeID != nil
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
        switch operation {
        case .sendMessage:
            try await sendTaskMessage(
                arguments: arguments, parent: fixed ? nil : controlInput, sessionID: sessionID, inputID: inputID)
            return .completed
        case .stateGet:
            return .value(try await readState(arguments, sessionID: sessionID))
        case .stateSet, .stateClear, .loadSkills, .releaseSkills:
            if let parked {
                guard parked.requestTaskID == (try await contextRepository.snapshot()).state.skillState?.activeTaskID
                else { throw CommunicationError.scopeClosed }
            }
            try stateContext?.open(session: sessionID)
            guard !taskControlInProgress else { throw AssistantHistoryError.busy }
            taskControlInProgress = true
            defer { taskControlInProgress = false }
            switch operation {
            case .stateSet, .stateClear:
                try await writeState(
                    operation, arguments: arguments, sessionID: sessionID, inputID: inputID, decisionID: decisionID)
                return .completed
            default:
                return try await controlSkills(operation, arguments: arguments, inputID: inputID)
            }
        }
    }

    // MARK: State

    /// The host writes the Agent's own variables, for example `quiet` from a do-not-disturb setting. `nil` clears.
    public func setHostState(_ name: String, to value: String?) async throws {
        let schema = try AgentConfigurations.stateSchema(named: State.configurationName)
        guard schema.declaration(boundTo: .task)?.name != name else { throw AgentStateError.unknownVariable(name) }
        try await contextRepository.transaction { context in
            var variables = context.state.variables
            if let value {
                try variables.set(name, value, source: .host, schema: schema)
            } else {
                try variables.clear(name, source: .host, schema: schema)
            }
            context.state.variables = variables
        }
    }

    /// `state.get`: an own variable by short name, or any state path the context can read.
    private func readState(_ arguments: [String: String], sessionID: String) async throws -> String {
        guard Set(arguments.keys) == ["path"], let path = arguments["path"]?.trimmingCharacters(in: .whitespaces),
            !path.isEmpty
        else { throw CommunicationError.invalidPayload }
        guard path.contains(".") else {
            guard AgentStateVariables.validName(path) else { throw AgentStateError.invalidName(path) }
            let visible = try await contextRepository.snapshot().state.visibleVariables(session: sessionID)
            var fields: [String: String?] = ["name": path, "value": visible.value(path)]
            if let entry = visible.entries[path] {
                fields["writtenAt"] = AgentStatePrompt.time(entry.writtenAt, language: AgentPrompts.language)
            }
            return String(
                decoding: try JSONSerialization.data(
                    withJSONObject: fields.mapValues { $0 ?? NSNull() as Any }, options: [.sortedKeys]),
                as: UTF8.self)
        }
        guard let stateContext else { throw CommunicationError.invalidPayload }
        try stateContext.open(session: sessionID)
        return try await stateContext.snapshot(session: sessionID, names: [path])
    }

    /// `state.set` / `state.clear`: the model and the host write only the Agent's own variables.
    private func writeState(
        _ operation: AgentControlOperation, arguments: [String: String], sessionID: String, inputID: String,
        decisionID: String?
    ) async throws {
        let setting = operation == .stateSet
        guard Set(arguments.keys).isSubset(of: setting ? ["name", "value", "note"] : ["name", "note"]),
            let name = arguments["name"], !setting || arguments["value"] != nil,
            arguments.values.allSatisfy({ $0.utf8.count <= 4096 })
        else { throw CommunicationError.invalidPayload }
        let schema = try AgentConfigurations.stateSchema(named: State.configurationName)
        let source: AgentStateSource = decisionID == nil ? .host : .model
        let note = arguments["note"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if schema.declaration(boundTo: .task)?.name == name {
            try await writeTask(
                setting: setting, name: name, value: arguments["value"], note: note, source: source,
                schema: schema, sessionID: sessionID, inputID: inputID, decisionID: decisionID)
        } else {
            try await contextRepository.transaction { context in
                var variables = context.state.variables
                if setting {
                    try variables.set(name, arguments["value"] ?? "", source: source, schema: schema, note: note)
                } else {
                    try variables.clear(name, source: source, schema: schema, note: note)
                }
                context.state.variables = variables
            }
        }
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

    // MARK: Skills

    private func controlSkills(_ operation: AgentControlOperation, arguments: [String: String], inputID: String)
        async throws -> ActionCompletion
    {
        let fixedCapabilities = descriptor.capabilities
        let result = try await contextRepository.transaction { context in
            guard var skills = context.state.skillState else { throw CommunicationError.invalidPayload }
            let result = try skills.control(
                operation.rawValue, arguments: arguments, inputID: inputID, fixed: fixedCapabilities)
            context.state.skillState = skills
            return result
        }
        if let committed = try await contextRepository.snapshot().state.skillState {
            skillContinuation.yield(committed)
        }
        try await conversations.checkpoint(inputID: inputID)
        return .value(result)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
