import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore

/// Preserve provider call/result blocks when interleaving independent task rounds.
public enum AgentChatContextBuilder {
    struct StateImageProjection {
        let messages: [ChatMessage]
        let manifest: String?
        let ephemeralIDs: Set<String>
    }

    /// Fresh State images belong to the current input, including continuations of that input.
    /// The system manifest maps IDs to image positions without changing the user's text.
    static func applyingStateImages(
        _ images: [ContextImage], to messages: [ChatMessage], user: String, supportsImages: Bool
    ) throws -> StateImageProjection {
        guard !images.isEmpty else { return .init(messages: messages, manifest: nil, ephemeralIDs: []) }
        guard let index = messages.lastIndex(where: { $0.role == .user && $0.content == user }) else {
            throw CapabilityError.invalidRequest("Missing current user input for State images")
        }
        var result = messages
        let input = messages[index]
        var attachments = input.images ?? []
        var entries: [[String: Any]] = []
        for image in images {
            var entry: [String: Any] = [
                "id": image.id, "source": image.source ?? "state", "mimeType": image.mimeType,
                "width": image.width, "height": image.height, "byteCount": image.data.count,
            ]
            if supportsImages {
                guard !attachments.contains(where: { $0.id == image.id }) else {
                    throw CapabilityError.invalidRequest("Duplicate current input image identity")
                }
                attachments.append(try ChatImage(id: image.id, mimeType: image.mimeType, data: image.data))
                entry["position"] = attachments.count
            }
            entries.append(entry)
        }
        let manifest: [String: Any] = [
            "message": "current_user_input", "content": "untrusted_image_data",
            "delivery": supportsImages ? "attached" : "unsupported",
            "images": entries,
        ]
        if supportsImages {
            guard attachments.count <= ChatRequest.maximumImageCount else {
                throw CapabilityError.invalidRequest("Too many current input images")
            }
            result[index] = .init(
                role: input.role, content: input.content, toolCalls: input.toolCalls,
                toolCallID: input.toolCallID, images: attachments)
        }
        return .init(
            messages: result,
            manifest: String(
                decoding: try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys), as: UTF8.self),
            ephemeralIDs: supportsImages ? Set(images.map(\.id)) : [])
    }

    /// Model-only projection. Causal IDs and full execution journals remain owned by the worker.
    static func actionObservation(
        index: Int, name: String, result: ToolResult, action: ActionResult? = nil,
        rejection: CallRejection? = nil
    ) -> [String: Any] {
        var value = compactResult(result, action: action, rejection: rejection)
        value["call"] = index
        value["action"] = name
        return value
    }

    static func nativeObservation(_ result: ToolResult, rejection: CallRejection? = nil) throws -> String {
        let isReport: Bool
        if case .report = result.completion { isReport = true } else { isReport = false }
        if !result.hasFailure && !result.isCancellationOnly && rejection == nil && !isReport { return result.value }
        return String(
            decoding: try JSONSerialization.data(
                withJSONObject: compactResult(result, rejection: rejection), options: [.sortedKeys]), as: UTF8.self)
    }

    static func compactResult(
        _ result: ToolResult, action: ActionResult? = nil, rejection: CallRejection? = nil
    ) -> [String: Any] {
        let report: AgentActionReport?
        if case .report(let value) = result.completion { report = value } else { report = nil }
        let status =
            rejection != nil
            ? "rejected"
            : action?.status.rawValue
                ?? (result.hasFailure
                    ? (report?.status.rawValue == "partialFailure" ? "partialFailure" : "failed")
                    : (result.isCancellationOnly ? "cancelled" : "succeeded"))
        var value: [String: Any] = ["status": status]
        // Decode only containers: scalar text, explicit empty values and opaque IDs remain exact.
        let business: Any =
            (try? JSONSerialization.jsonObject(with: Data(result.value.utf8))) ?? result.value
        if !result.hasFailure || business is [String: Any] || business is [Any] {
            value["value"] = business
        } else if case .value = result.completion {
            value["value"] = business
        }
        if rejection != nil {
            value["executed"] = false
        } else if let action, action.effect != .contractCompleted || action.status != .succeeded {
            value["effect"] = action.effect.rawValue
        } else if result.hasFailure && action == nil {
            value["effect"] = "unknown"
        }
        if result.hasFailure || rejection != nil {
            var error: [String: Any] = [:]
            if let code = rejection.map({ String(describing: $0.reason) }) ?? result.failureCode
                ?? report?.executionFailure?.rawValue ?? action?.failure?.rawValue
            {
                error["code"] = code
            }
            if !result.value.isEmpty, business is String { error["message"] = result.value }
            if !error.isEmpty { value["error"] = error }
        }
        if let report {
            var detail: [String: Any] = [:]
            if !report.entries.isEmpty {
                detail["entries"] = report.entries.map { entry -> [String: Any] in
                    var leaf: [String: Any] = ["path": entry.path, "status": entry.status.rawValue]
                    if let code = entry.code { leaf["code"] = code.rawValue }
                    if !entry.details.isEmpty { leaf["details"] = entry.details }
                    return leaf
                }
            }
            if let code = report.executionFailure { detail["executionFailure"] = code.rawValue }
            if let description = report.failureDescription, !description.isEmpty {
                detail["failureDescription"] = description
            }
            if !detail.isEmpty { value["report"] = detail }
        }
        return value
    }

    /// Retire oldest complete blocks in the model projection; durable history is unchanged.
    public static func retainingRecent(
        _ messages: [ChatMessage], preservingUser user: String, protectedSuffixCount: Int = 1,
        reservingMessages: Int = 0, reservingBytes: Int = 0, protectedImageIDs: Set<String> = []
    ) throws -> [ChatMessage] {
        var groups: [[Int]] = []
        var index = 0
        while index < messages.count {
            let start = index
            let message = messages[index]
            if message.role == .tool { throw CapabilityError.invalidRequest("Uncorrelated tool result") }
            index += 1
            if !message.toolCalls.isEmpty {
                var pending = Set(message.toolCalls.map(\.id))
                while index < messages.count, messages[index].role == .tool {
                    guard let id = messages[index].toolCallID, pending.remove(id) != nil else {
                        throw CapabilityError.invalidRequest("Uncorrelated tool result")
                    }
                    index += 1
                }
                guard pending.isEmpty else { throw CapabilityError.invalidRequest("Incomplete tool transcript") }
            }
            groups.append(Array(start..<index))
        }
        let intent = messages.lastIndex { $0.role == .user && $0.content == user }
        let suffixStart = max(0, messages.count - protectedSuffixCount)
        func protected(_ group: [Int]) -> Bool {
            group.contains {
                messages[$0].role == .system || $0 == intent || $0 >= suffixStart
                    || (messages[$0].images ?? []).contains { protectedImageIDs.contains($0.id) }
            }
        }
        while true {
            let selected = groups.flatMap { $0.map { messages[$0] } }
            let bytes = selected.reduce(0) { $0 + textBytes($1) }
            let images = selected.reduce(0) { $0 + ($1.images?.count ?? 0) }
            if selected.count + reservingMessages <= 64 && bytes + reservingBytes <= 65_536
                && images <= ChatRequest.maximumImageCount
            {
                return selected
            }
            guard let oldest = groups.firstIndex(where: { !protected($0) }) else {
                throw CapabilityError.invalidRequest("Current intent/results exceed model request capacity")
            }
            groups.remove(at: oldest)
        }
    }
    static func textBytes(_ message: ChatMessage) -> Int {
        message.content.utf8.count + (message.toolCallID?.utf8.count ?? 0)
            + message.toolCalls.reduce(0) { $0 + $1.id.utf8.count + $1.name.utf8.count + $1.argumentsJSON.utf8.count }
    }

    public static func project(_ messages: [ChatMessage]) -> [ModelMessage] {
        messages.compactMap {
            guard let role = ModelMessage.Role(rawValue: $0.role.rawValue) else { return nil }
            return ModelMessage(role: role, content: $0.content)
        }
    }
    public static func request(
        system: String, user: String, conversation: AssistantConversation, nativeHistory: Bool = true,
        templates: PromptTemplates
    ) throws -> [ChatMessage] {
        var selected: [[ChatMessage]] = []
        for item in try conversation.indexedHistory().filter({ item in
            if case .request(_, let request) = item { return request.state != .generating }
            return true
        }).suffix(10) {
            switch item {
            case .task(let compression):
                selected.append([try compressionMessage(compression)])
            case .request(_, let request):
                guard request.state != .generating, request.awaitingDispatch != true else { continue }
                let paired = request.state == .completed && request.toolCalls.allSatisfy({ $0.state != .received })
                selected.append(
                    try messages(for: request, nativeHistory: nativeHistory && paired, templates: templates))
            }
        }
        return [ChatMessage(role: .system, content: system)] + selected.suffix(10).flatMap { $0 }
            + [ChatMessage(role: .user, content: user)]
    }
    public static func compressionMessage(_ compression: AssistantTaskCompression) throws -> ChatMessage {
        var value = [
            "taskID": compression.taskID, "goal": compression.goal, "status": compression.status.rawValue,
        ]
        if let summary = compression.reportedSummary { value["reportedSummary"] = summary }
        if let failure = compression.failure { value["failure"] = failure }
        value["sourceRequestCount"] = String(compression.sources.count)
        return .init(
            role: .user,
            content: "Task history (historical data): "
                + String(
                    decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }

    public static func messages(
        for invocation: AssistantModelRequest, nativeHistory: Bool = true, templates: PromptTemplates
    ) throws -> [ChatMessage] {
        let input = AssistantInputBatch.historyText(invocation.input)
        if !nativeHistory {
            let evidence = try invocation.toolCalls.map { call in
                try templates.render(
                    "historicalExecution",
                    variables: [
                        "name": call.name, "state": call.state.rawValue, "arguments": call.argumentsJSON,
                        "result": call.output ?? "", "error": call.error ?? "",
                    ])
            }.joined(separator: "\n")
            let text = invocation.response + (evidence.isEmpty ? "" : "\n" + evidence)
            return [.init(role: .user, content: input), .init(role: .assistant, content: text)]
        }
        let calls = invocation.toolCalls.map {
            ChatToolCall(id: $0.providerID, name: $0.name, argumentsJSON: $0.argumentsJSON)
        }
        var messages = [
            ChatMessage(role: .user, content: input),
            ChatMessage(role: .assistant, content: invocation.response, toolCalls: calls),
        ]
        for call in invocation.toolCalls {
            let content: String
            if call.state == .failed || call.state == .cancelled {
                content = try templates.render(
                    "toolFailure", variables: ["error": call.error ?? "unknown", "output": call.output ?? ""])
            } else {
                content = call.output ?? ""
            }
            messages.append(ChatMessage(role: .tool, content: content, toolCallID: call.providerID))
        }
        return messages
    }
}

struct AgentChatRequestBuilder<State: AgentChatContextState>: ContextBuilder {
    struct Request: Sendable {
        let input: AgentInput
        let state: State
        let batch: SignalBatch
        let conversation: AssistantConversation
        func messages(system: String, user: String) throws -> [ChatMessage] {
            try State.buildChatMessages(system: system, user: user, conversation: conversation)
        }
    }
    func build(state: AgentDecisionContext<State>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        var conversation = state.snapshot.state.history.current
        if batch.signalIDs.count > 1 {
            let members = Set(batch.signalIDs)
            conversation.turns.removeAll { members.contains($0.id) }
            conversation.taskCompressions.removeAll { compression in
                compression.sources.contains { members.contains($0.inputID) }
            }
        }
        if let task = input.taskScope {
            let ids = Set(
                state.snapshot.records.filter { $0.taskID == task.id }.compactMap {
                    try? JSONDecoder().decode(SignalEvidence.self, from: $0.data).signalID
                })
            conversation.turns = conversation.turns.filter { ids.contains($0.id) }
            conversation.taskCompressions.removeAll { !$0.sources.allSatisfy { ids.contains($0.inputID) } }
        }
        return Request(input: input, state: state.snapshot.state, batch: batch, conversation: conversation)
    }
}
