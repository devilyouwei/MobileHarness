import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore

/// Assistant-owned selection and reconstruction of durable conversation evidence.
public enum AssistantHistoryProjection {
    /// Read only the current dialog's earlier, dispatched exchange, including a reply still streaming.
    static func decisionExchange(in conversation: AssistantConversation, before inputID: String)
        -> InputDecisionSnapshot.Exchange?
    {
        guard let boundary = conversation.turns.firstIndex(where: { $0.id == inputID }) else { return nil }
        let earlier = conversation.turns[..<boundary]
        func isUser(_ turn: AssistantRecord) -> Bool {
            guard !turn.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let evidence = turn.coordination else { return true }
            if let action = evidence.decision { return action != InputDisposition.discard.rawValue }
            return evidence.source == "user" || evidence.source == AgentID.speechPerception.rawValue
        }
        for turn in earlier.reversed() {
            guard
                let request = turn.modelRequests?.last(where: {
                    $0.awaitingDispatch != true && $0.state != .failed && $0.state != .cancelled
                        && !$0.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            else { continue }
            if let members = turn.coordination?.memberIDs, members.count > 1,
                let user = earlier.last(where: { members.contains($0.id) && isUser($0) })
            {
                return .init(user: user.user, assistant: request.response)
            }
            if isUser(turn) {
                return .init(user: turn.user, assistant: request.response)
            }
        }
        return nil
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
            content: try AgentPrompts.text("Assistant/Prompts", "taskHistory")
                + String(
                    decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }

    public static func messages(
        for invocation: AssistantModelRequest, nativeHistory: Bool = true, templates: PromptTemplates
    ) throws -> [ChatMessage] {
        let input = try AssistantInputBatch.historyText(invocation.input)
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

struct AssistantChatRequestBuilder<State: AssistantChatState>: ContextBuilder {
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
