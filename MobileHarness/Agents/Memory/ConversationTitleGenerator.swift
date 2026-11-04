import AgentCore
import Foundation
import ModelKit
import StorageChat

/// Title-only inference: never parses Action markup, changes context or executes model output.
public enum ConversationTitleGenerator {
    public static func samplePositions(count: Int) -> [Int] {
        let amount = min(32, count)
        return (0..<amount).map { amount == 1 ? 0 : $0 * (count - 1) / (amount - 1) }
    }
    public static func summarize(_ conversation: StoredConversation, using chat: any ChatCapability) async throws
        -> String
    {
        guard !conversation.turns.isEmpty else { throw ConversationHistoryError.emptyConversation }
        // Bounded excerpts cover the whole conversation, rather than only its final exchange.
        let selected = samplePositions(count: conversation.turns.count).map { conversation.turns[$0] }
        let templates = try PromptTemplates(data: AgentConfigurations.titlePromptData())
        let excerpts = try selected.map {
            try templates.render(
                "title.excerpt",
                variables: [
                    "user": String($0.user.prefix(80)), "assistant": String($0.raw.prefix(80)),
                ])
        }.joined(separator: "\n")
        let request = try ChatRequest(
            messages: [
                .init(role: .system, content: try templates.render("title.system")),
                .init(role: .user, content: try templates.render("title.user", variables: ["excerpts": excerpts])),
            ], temperature: 0)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = try await chat.chat(request)
                defer { session.cancel() }
                return try await withTaskCancellationHandler {
                    var title = ""
                    var finished = false
                    for try await event in session.events {
                        try Task.checkCancellation()
                        guard !finished else { throw CapabilityError.invalidRequest("Events after title completion") }
                        switch event {
                        case .text(let delta):
                            guard title.utf8.count + delta.utf8.count <= 1024 else {
                                throw CapabilityError.eventTooLarge
                            }
                            title += delta
                        case .usage: break
                        case .toolCall:
                            throw CapabilityError.invalidRequest("Unexpected title tool call")
                        case .finished(let reason):
                            guard reason == .stop else {
                                throw CapabilityError.invalidRequest("Incomplete conversation title")
                            }
                            finished = true
                        }
                    }
                    let result = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard finished, !result.isEmpty, result.count <= 80,
                        !result.contains("\n"), !result.contains("<"), !result.contains(">")
                    else {
                        throw CapabilityError.invalidRequest("Invalid conversation title")
                    }
                    return result
                } onCancel: {
                    session.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw CapabilityError.unavailable("Conversation title generation timed out")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}
