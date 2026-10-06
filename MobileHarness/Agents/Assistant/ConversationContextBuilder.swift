import Foundation
import StorageChat

/// Assistant policy; Storage retains the exact resulting request.
public enum ConversationContextBuilder {
    public static func request(
        system: String, user: String, conversation: StoredConversation
    ) -> [ConversationMessage] {
        var messages = [ConversationMessage(role: .system, content: system)]
        for turn in conversation.turns.filter({ $0.state == .completed }).suffix(10) {
            messages += [.init(role: .user, content: turn.user), .init(role: .assistant, content: turn.raw)]
        }
        messages.append(.init(role: .user, content: user))
        return messages
    }
}
