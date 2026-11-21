import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    /// Actual Action outcomes survive context reconstruction; no private Task/Skill state summary.
    func roundActionResultMessages() throws -> [ChatMessage] {
        let actions = try roundCalls.enumerated().filter {
            !$0.element.tool && !isInternalRuntimeCall($0.element) && $0.element.result?.requiresReasoning == true
        }.map { index, call -> [String: Any] in
            guard let result = call.result else { throw CommunicationError.invalidPayload }
            return AgentChatContextBuilder.actionObservation(
                index: index + 1, name: observationName(call), result: result,
                action: call.actionResult, rejection: call.rejection)
        }
        guard !actions.isEmpty else { return [] }
        let data = try JSONSerialization.data(withJSONObject: actions, options: [.sortedKeys])
        return [
            .init(
                role: .user,
                content: try AgentPrompts.load(named: State.configurationName).render(
                    "executionObservations", variables: ["data": String(decoding: data, as: UTF8.self)]))
        ]
    }
    func isInternalRuntimeCall(_ call: RoundCall) -> Bool {
        !call.modelGenerated
    }
    func observationName(_ call: RoundCall) -> String {
        call.rejection?.alias
            ?? requestCatalog?.actions.first(where: { $0.path.description == call.path })?.alias
            ?? requestCatalog?.controls.first(where: { $0.path.description == call.path })?.alias ?? call.path
    }

    struct HistoryImageReference: Encodable {
        let id: String
        let mimeType: String
        let byteCount: Int
        let resourceScope: String?
    }
    struct HistoryRequestMessage: Encodable {
        let role: ChatMessage.Role
        let content: String
        let toolCalls: [ChatToolCall]
        let toolCallID: String?
        let imageReferences: [HistoryImageReference]
    }
    static func historyRequest(_ messages: [ChatMessage], imageScopes: [String: String] = [:]) throws -> String {
        let records = messages.map { message in
            HistoryRequestMessage(
                role: message.role, content: message.content, toolCalls: message.toolCalls,
                toolCallID: message.toolCallID,
                imageReferences: (message.images ?? []).map {
                    HistoryImageReference(
                        id: $0.id, mimeType: $0.mimeType, byteCount: $0.data.count, resourceScope: imageScopes[$0.id])
                })
        }
        return String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    }

    func persistFeedback(_ input: AgentInput) async throws {
        do { try await prepareSignal(input) } catch {
            feedbackFailure = "Execution feedback persistence failed: \(error)"
            throw error
        }
    }
    func acceptPendingFeedback(_ input: AgentInput) async throws -> Bool {
        let key: String?
        switch input.payload {
        case .roundResult(let value): key = value.roundID
        case .actionResult(let value): key = value.roundID
        case .toolResult(let value):
            key =
                value.roundID ?? pendingRounds.first(where: { $0.value.calls.contains { $0.id == value.callID } })?.key
        default: return false
        }
        guard let key, let pending = pendingRounds[key] else { return false }
        guard input.metadata.origin == .runtime, input.metadata.source == "runtime",
            input.sessionID == pending.input.sessionID, input.metadata.parentID == pending.input.id,
            input.metadata.rootID == pending.input.metadata.rootID, input.turn == pending.input.turn
        else {
            throw CommunicationError.unauthorized
        }
        try await persistFeedback(input)
        guard var current = pendingRounds[key] else { return true }
        switch input.payload {
        case .roundResult(let value):
            guard current.receipt == nil else { throw CommunicationError.unauthorized }
            current.receipt = value
        case .toolResult(let value):
            guard let index = current.calls.firstIndex(where: { $0.tool && $0.id == value.callID && $0.result == nil })
            else { throw CommunicationError.unauthorized }
            try await conversations.recordToolOutcome(
                value.callID, for: current.input.id,
                state: value.isCancellationOnly ? .cancelled : (value.hasFailure ? .failed : .completed),
                output: value.value, error: value.failureCode)
            guard let latest = pendingRounds[key] else { return true }
            current = latest
            guard current.calls[index].result == nil else { throw CommunicationError.unauthorized }
            try current.coordinator?.accept(value, roundID: key)
            current.calls[index].result = value
            current.calls[index].completedAt = Date()
        case .actionResult(let value):
            guard value.owner.agent == descriptor.id, value.owner.sessionID == input.sessionID,
                let index = current.calls.firstIndex(where: { !$0.tool && $0.id == value.callID && $0.result == nil }),
                current.calls[index].path == value.path.description
            else { throw CommunicationError.unauthorized }
            let result = ToolResult(
                callID: current.calls[index].id, value: try Self.completionText(value.completion),
                isError: value.status != .succeeded, failureCode: value.failure?.rawValue,
                completion: value.completion ?? .completed, roundID: key)
            try current.coordinator?.accept(result, roundID: key)
            current.calls[index].result = result
            current.calls[index].actionResult = value
            current.calls[index].completedAt = Date()
            resultInbox.accept(value)
        default: return false
        }
        current.resultBytes = try current.calls.compactMap(\.result).reduce(0) {
            try $0 + Self.observationText($1).utf8.count
        }
        if current.resultBytes > 65_536 { throw CommunicationError.invalidPayload }
        pendingRounds[key] = current
        try await publishPendingResults(key)
        if lifecycle == .running { drain() }
        return true
    }

    /// Per-call Action results are ready independently of other output channels.
    /// The flag owns publication across suspension points and prevents settlement from overtaking it.
    func publishPendingResults(_ key: String) async throws {
        guard var pending = pendingRounds[key], !pending.publishing else { return }
        pending.publishing = true
        pendingRounds[key] = pending
        do {
            while let current = pendingRounds[key], !current.cancelled,
                let index = current.calls.firstIndex(where: {
                    !$0.tool && $0.modelGenerated && !$0.forwarded && $0.result?.requiresReasoning == true
                })
            {
                try await enqueueActionResult(
                    current.calls[index], input: current.input, chat: current.chat, pendingKey: key)
                pendingRounds[key]?.calls[index].forwarded = true
            }
            if let current = pendingRounds[key], !current.cancelled {
                let tools = current.calls.filter(\.tool)
                if tools.allSatisfy({ $0.result != nil }),
                    tools.contains(where: { !$0.forwarded && $0.result?.requiresReasoning == true })
                {
                    try await enqueueNativeResults(
                        tools, input: current.input, round: key,
                        text: current.text, chat: current.chat, pendingKey: key)
                    for index in current.calls.indices where current.calls[index].tool {
                        pendingRounds[key]?.calls[index].forwarded = true
                    }
                }
            }
        } catch {
            pendingRounds[key]?.publishing = false
            // Admission/attachment failure is explicit. The result remains unforwarded for settlement.
            emitFailure(error, for: pending.input)
        }
        guard var current = pendingRounds[key] else { return }
        current.publishing = false
        if current.receipt != nil, !current.queued {
            try queue.admit(current.input, disposition: .enqueue(priority: 100))
            current.queued = true
        }
        pendingRounds[key] = current
    }

    func enqueueActionResult(
        _ call: RoundCall, input: AgentInput, chat: any ChatCapability, pendingKey: String? = nil
    ) async throws {
        guard let result = call.result, result.requiresReasoning else { return }
        let observation = AgentChatContextBuilder.compactResult(
            result, action: call.actionResult, rejection: call.rejection)
        let content = String(
            decoding: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), as: UTF8.self)
        let payload = InputPayload.text(content)
        let candidate = AgentInput(
            id: call.id + ".result", sessionID: input.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "action." + call.path, origin: .runtime,
                rootID: input.metadata.rootID, parentID: input.id),
            turn: input.turn, taskScope: input.taskScope)
        let semantic = try makeSemanticMessage(
            input: candidate, role: .action, channel: "action." + call.path, content: content, time: call.completedAt)
        let attachments = try await observations([.init(path: call.path, result: result)], input, chat)
        try Task.checkCancellation()
        if let pendingKey {
            guard let pending = pendingRounds[pendingKey], !pending.cancelled else { throw CancellationError() }
        }
        try await receiveSignal(candidate, semantic: semantic, attachments: attachments)
    }

    func enqueueNativeResults(
        _ calls: [RoundCall], input: AgentInput, round: String, text: String, chat: any ChatCapability,
        pendingKey: String? = nil
    ) async throws {
        var attachments = [ChatMessage(role: .assistant, content: text, toolCalls: calls.compactMap(\.native))]
        for call in calls {
            guard let native = call.native, let result = call.result else { throw CommunicationError.invalidPayload }
            attachments.append(
                .init(
                    role: .tool,
                    content: try AgentChatContextBuilder.nativeObservation(result, rejection: call.rejection),
                    toolCallID: native.id))
        }
        attachments += try await observations(
            calls.compactMap { call in
                guard let result = call.result, result.requiresReasoning else { return nil }
                return .init(path: call.path, result: result)
            }, input, chat)
        let content = try AgentPrompts.text("Assistant/Input/InputProtocol", "pairedResults")
        let payload = InputPayload.text(content)
        let candidate = AgentInput(
            id: round + ".tools", sessionID: input.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "action.tools", origin: .runtime,
                rootID: input.metadata.rootID, parentID: input.id),
            turn: input.turn, taskScope: input.taskScope)
        let semantic = try makeSemanticMessage(
            input: candidate, role: .action, channel: "action.tools",
            content: content, time: calls.compactMap(\.completedAt).max())
        try Task.checkCancellation()
        if let pendingKey {
            guard let pending = pendingRounds[pendingKey], !pending.cancelled else { throw CancellationError() }
        }
        try await receiveSignal(candidate, semantic: semantic, attachments: attachments)
    }

    func validateFeedback(_ input: AgentInput) throws {
        guard let activeInput, roundID != nil, input.metadata.origin == .runtime,
            input.metadata.source == "runtime", input.sessionID == activeInput.sessionID,
            input.metadata.parentID == activeInput.id, input.metadata.rootID == activeInput.metadata.rootID,
            input.turn == activeInput.turn
        else { throw CommunicationError.unauthorized }
    }
    func acceptResult(_ result: ToolResult, at index: Int) throws {
        guard roundCalls.indices.contains(index), roundCalls[index].id == result.callID, roundCalls[index].result == nil
        else { throw CommunicationError.unauthorized }
        let bytes = try Self.observationText(result).utf8.count
        guard resultBytes + bytes <= 65_536 else {
            feedbackFailure = "Generation feedback exceeds 64 KiB"
            throw CommunicationError.invalidPayload
        }
        guard let roundID else { throw CommunicationError.scopeClosed }
        try roundCoordinator?.accept(result, roundID: roundID)
        resultBytes += bytes
        roundCalls[index].result = result
        roundCalls[index].completedAt = Date()
    }
    func retireRound() {
        roundCalls.removeAll()
        roundReceipt = nil
    }
    static func completionText(_ completion: AgentActionCompletion?) throws -> String {
        switch completion {
        case .value(let value): return value
        case .completed: return "completed"
        case .activityStarted(let id): return "activityStarted:\(id)"
        case .activityStopped(let id): return "activityStopped:\(id)"
        case .report(let report): return report.failureDescription ?? report.status.rawValue
        case nil: return try AgentPrompts.text("Shared/ExecutionFeedback", "missingCompletion")
        }
    }
    static func observationText(_ result: ToolResult) throws -> String {
        guard
            result.hasFailure
                || {
                    if case .report = result.completion { true } else { false }
                }()
        else { return result.value }
        var object: [String: Any] = ["isError": result.hasFailure, "value": result.value]
        if let code = result.failureCode { object["failureCode"] = code }
        if case .report(let report) = result.completion {
            object["report"] =
                [
                    "status": report.status.rawValue,
                    "entries": report.entries.map { entry -> [String: Any] in
                        var leaf: [String: Any] = [
                            "path": entry.path, "status": entry.status.rawValue, "details": entry.details,
                        ]
                        if let code = entry.code { leaf["code"] = code.rawValue }
                        return leaf
                    },
                    "executionFailure": report.executionFailure?.rawValue ?? NSNull(),
                    "failureDescription": report.failureDescription ?? NSNull(),
                ] as [String: Any]
        }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
