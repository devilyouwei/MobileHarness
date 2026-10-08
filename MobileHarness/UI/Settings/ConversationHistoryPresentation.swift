import Foundation

public enum ConversationHistoryPresentation {
    public static func title(_ conversation: HistoryConversation) -> String {
        if conversation.archivedAt != nil { return conversation.summaryTitle ?? "待生成标题" }
        return conversation.turns.last?.user ?? "新对话"
    }
}
