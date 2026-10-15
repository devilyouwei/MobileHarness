import AgentCore
import Foundation
import ModelKit
import Storage
import StorageChat

/// Preserve provider call/result blocks when interleaving independent task rounds.
public enum AgentChatContextBuilder {
    /// Retire oldest complete blocks in the model projection; durable history is unchanged.
    public static func retainingRecent(
        _ messages: [ChatMessage], preservingUser user: String, protectedSuffixCount: Int = 1,
        reservingMessages: Int = 0, reservingBytes: Int = 0
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
            group.contains { messages[$0].role == .system || $0 == intent || $0 >= suffixStart }
        }
        while true {
            let selected = groups.flatMap { $0.map { messages[$0] } }
            let bytes = selected.reduce(0) { $0 + textBytes($1) }
            let images = selected.reduce(0) { $0 + ($1.images?.count ?? 0) }
            if selected.count + reservingMessages <= 64 && bytes + reservingBytes <= 65_536 && images <= 4 {
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

    /// Runtime facts are scoped data; retained task history is not an instruction catalog.
    static func taskReports(
        views: [String: AgentTaskView], tasks: AgentTaskRegistry, input: AgentInput, templates: PromptTemplates
    ) throws -> String {
        let selected = views.values.filter { view in
            guard view.scope.sessionID == input.sessionID else { return false }
            if view.scope.id == input.taskScope?.id { return true }
            guard view.scope.execution == .background, !view.terminal,
                let record = tasks.task(view.scope.id)
            else { return false }
            return ![.succeeded, .failed, .cancelled, .interrupted].contains(record.state)
        }.sorted { ($0.createdAt ?? .distantPast, $0.scope.id) < ($1.createdAt ?? .distantPast, $1.scope.id) }.prefix(
            17)
        guard !selected.isEmpty else { return "" }
        let reports = try selected.map { view in
            try templates.render(
                "taskReport",
                variables: [
                    "taskID": view.scope.id, "executor": view.scope.executor.rawValue,
                    "status": tasks.task(view.scope.id)?.state.rawValue ?? "unknown", "stage": view.stage.rawValue,
                    "interaction": view.interactionID ?? "none",
                    "artifact": view.artifactID ?? "none", "report": String(view.text.prefix(128)),
                ])
        }.joined(separator: "\n")
        return try templates.render("taskReports", variables: ["reports": reports])
    }

    public static func historyProjection(
        system: String, user: String, conversation: StoredConversation, templates: PromptTemplates
    ) throws -> [ConversationMessage] {
        project(try request(system: system, user: user, conversation: conversation, templates: templates))
    }
    public static func project(_ messages: [ChatMessage]) -> [ConversationMessage] {
        messages.compactMap {
            guard let role = ConversationMessage.Role(rawValue: $0.role.rawValue) else { return nil }
            return ConversationMessage(role: role, content: $0.content)
        }
    }
    public static func request(
        system: String, user: String, conversation: StoredConversation, nativeHistory: Bool = true,
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
                guard request.state != .generating else { continue }
                let paired = request.state == .completed && request.toolCalls.allSatisfy({ $0.state != .received })
                selected.append(
                    try messages(for: request, nativeHistory: nativeHistory && paired, templates: templates))
            }
        }
        return [ChatMessage(role: .system, content: system)] + selected.suffix(10).flatMap { $0 }
            + [ChatMessage(role: .user, content: user)]
    }
    public static func compressionMessage(_ compression: ConversationTaskCompression) throws -> ChatMessage {
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
        for invocation: ConversationModelRequest, nativeHistory: Bool = true, templates: PromptTemplates
    ) throws -> [ChatMessage] {
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
            return [.init(role: .user, content: invocation.input), .init(role: .assistant, content: text)]
        }
        let calls = invocation.toolCalls.map {
            ChatToolCall(id: $0.providerID, name: $0.name, argumentsJSON: $0.argumentsJSON)
        }
        var messages = [
            ChatMessage(role: .user, content: invocation.input),
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
