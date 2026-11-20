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

    func finishForegroundTask(summary: String, sessionID: String) async throws {
        guard let assistant = agent.withLock({ $0 }) else { throw CommunicationError.unavailableTarget }
        _ = try await assistant.controlTask(
            .finishTask, arguments: ["summary": summary], source: AgentID.assistant.rawValue, sessionID: sessionID,
            inputID: UUID().uuidString, decisionID: nil)
    }
}

extension AssistantChatWorker {
    /// Runs a control owned by the Assistant; it never reaches the Actions Shell.
    func executeControl(path: String, arguments: [String: String], input: AgentInput, callID: String)
        async throws -> ToolResult
    {
        guard let control = try AssistantControls.control(path: path) else { throw HarnessError.forbiddenFunction }
        do {
            let completion = try await controlTask(
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

    public func controlTask(
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
        switch operation {
        case .sendMessage:
            try await sendTaskMessage(
                arguments: arguments, parent: fixed ? nil : controlInput, sessionID: sessionID, inputID: inputID)
            return .completed
        case .startTask, .finishTask, .loadSkills, .releaseSkills:
            if let parked {
                guard parked.requestTaskID == (try await contextRepository.snapshot()).state.skillState?.activeTaskID
                else { throw CommunicationError.scopeClosed }
            }
            return try await controlLocalTaskAndSkills(
                operation, arguments: arguments, sessionID: sessionID, inputID: inputID, decisionID: decisionID)
        }
    }

    func controlLocalTaskAndSkills(
        _ operation: AgentControlOperation, arguments: [String: String], sessionID: String, inputID: String,
        decisionID: String?
    ) async throws -> ActionCompletion {
        let fixed = decisionID == nil
        try stateContext?.open(session: sessionID)
        guard !taskControlInProgress else { throw AssistantHistoryError.busy }
        taskControlInProgress = true
        defer { taskControlInProgress = false }
        if operation == .finishTask, fullDuplex || fixed {
            return try await completeForegroundTask(arguments: arguments, inputID: inputID, requestID: decisionID)
        }
        let fixedCapabilities = descriptor.capabilities
        var newTaskID: String?
        if operation == .startTask {
            guard Set(arguments.keys).isSubset(of: ["description", "skills"]) else {
                throw CommunicationError.invalidPayload
            }
            var preview = try await contextRepository.snapshot().state.skillState
            guard preview != nil else { throw CommunicationError.invalidPayload }
            guard preview?.activeTaskID == nil else { throw CommunicationError.scopeClosed }
            // Validate all Skill/state constraints without changing the authoritative context.
            _ = try preview?.control(
                operation.rawValue, arguments: arguments, inputID: inputID,
                fixed: fixedCapabilities, sessionID: sessionID, taskID: "task_1")
            guard let taskRecords else { throw RecordStorageError.missingRecord }
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
                if fixed && operation == .loadSkills && skills.activeTaskID == nil {
                    throw CommunicationError.scopeClosed
                }
                let result = try skills.control(
                    operation.rawValue, arguments: arguments, inputID: inputID, fixed: fixedCapabilities,
                    sessionID: sessionID,
                    taskID: committedTaskID)
                if operation == .startTask, let decisionID, let taskID = skills.activeTaskID {
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
            skillContinuation.yield(committed)
        }
        try await conversations.checkpoint(inputID: inputID)
        return .value(result)
    }

    func completeForegroundTask(arguments: [String: String], inputID: String, requestID: String?) async throws
        -> ActionCompletion
    {
        let fixed = descriptor.capabilities
        guard var skills = try await contextRepository.snapshot().state.skillState,
            let task = skills.tasks.first(where: { $0.id == skills.activeTaskID }),
            requestID == nil || skills.taskID(for: inputID) == task.id, let summary = arguments["summary"]
        else { throw CommunicationError.scopeClosed }
        _ = try skills.control(
            AgentControlOperation.finishTask.rawValue, arguments: arguments, inputID: inputID, fixed: fixed)
        let finishedAt = Date()
        try await conversations.completeForegroundTask(
            task.id, goal: task.goal, summary: summary, finishedAt: finishedAt, inputID: inputID, requestID: requestID
        ) { [contextRepository] archive, persist in
            try await contextRepository.transaction(beforePublishing: persist) { context in
                guard var skills = context.state.skillState, skills.activeTaskID == task.id,
                    context.state.history.revision == archive.revision - 1
                else { throw CommunicationError.scopeClosed }
                _ = try skills.control(
                    AgentControlOperation.finishTask.rawValue, arguments: arguments, inputID: inputID, fixed: fixed)
                try skills.settleTask(finishedAt: finishedAt)
                context.state.skillState = skills
                context.state.history = archive
            }
        }
        if let skills = try await contextRepository.snapshot().state.skillState { skillContinuation.yield(skills) }
        guard arguments["continueDecision"] == "true" else { return .completed }
        let receipt = [
            "operation": AgentControlOperation.finishTask.rawValue, "status": "completed", "taskID": task.id,
        ]
        return .value(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))
    }
}
