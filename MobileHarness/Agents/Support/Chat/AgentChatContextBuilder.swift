import AgentCore
import Foundation
import ModelKit
import StorageChat

/// Preserve provider call/result blocks when interleaving independent task rounds.
public enum AgentChatContextBuilder {
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
        var selected: [(Date, [ChatMessage])] = []
        for turn in conversation.turns {
            if let requests = turn.modelRequests {
                for request in requests
                where request.state == .completed && request.toolCalls.allSatisfy({ $0.state != .received }) {
                    selected.append(
                        (request.date, try messages(for: request, nativeHistory: nativeHistory, templates: templates)))
                }
            } else if turn.state == .completed {
                selected.append(
                    (
                        turn.date,
                        [
                            ChatMessage(role: .user, content: turn.user),
                            ChatMessage(role: .assistant, content: turn.raw),
                        ]
                    ))
            }
        }
        return [ChatMessage(role: .system, content: system)] + selected.sorted { $0.0 < $1.0 }.suffix(10).flatMap(\.1)
            + [ChatMessage(role: .user, content: user)]
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
            let text = invocation.fragments.joined() + (evidence.isEmpty ? "" : "\n" + evidence)
            return [.init(role: .user, content: invocation.input), .init(role: .assistant, content: text)]
        }
        let calls = invocation.toolCalls.map {
            ChatToolCall(id: $0.providerID, name: $0.name, argumentsJSON: $0.argumentsJSON)
        }
        var messages = [
            ChatMessage(role: .user, content: invocation.input),
            ChatMessage(role: .assistant, content: invocation.fragments.joined(), toolCalls: calls),
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
