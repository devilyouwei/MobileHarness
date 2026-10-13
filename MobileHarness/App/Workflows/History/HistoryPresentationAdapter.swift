import Actions
import AgentCore
import Agents
import Foundation
import FunctionContracts
import StorageChat
import UI

/// Data adaptation only; permission and user intent belong to the gateways/Agent.
@MainActor
public final class HistoryPresentationAdapter: HistoryPresentationCapability {
    private let state: ConversationHistoryState
    private let store: ConversationHistoryStore
    private let sessionID: UUID
    public init(
        state: ConversationHistoryState, store: ConversationHistoryStore, sessionID: UUID
    ) {
        self.state = state
        self.store = store
        self.sessionID = sessionID
    }
    public static func presentationSnapshot(_ snapshot: ConversationArchive) throws -> HistorySnapshot {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= ConversationHistoryStore.maximumBytes else {
            throw HistoryIntentFailure.execution("History snapshot exceeds limit")
        }
        return try JSONDecoder().decode(HistorySnapshot.self, from: data)
    }
    public static func listPresentation(_ store: ConversationHistoryStore) async throws -> HistorySnapshot {
        let records = try await store.listConversations().map { conversation -> StoredConversation in
            var metadata = conversation
            metadata.turnCount = conversation.turnCount ?? conversation.turns.count
            metadata.latestUser = conversation.latestUser ?? conversation.turns.last.map { String($0.user.prefix(80)) }
            metadata.turns = []
            metadata.taskCompressions = []
            return metadata
        }
        guard let current = records.first else { throw HistoryDetailError.unavailable }
        var archive = ConversationArchive()
        archive.current = current
        archive.past = Array(records.dropFirst())
        return try presentationSnapshot(archive)
    }
    public static func conversation(_ value: StoredConversation) throws -> HistoryConversation {
        try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(value))
    }
    public static func assistantTasks(
        _ context: AgentContext<AssistantContextState>, history: ConversationArchive? = nil
    ) throws -> HistoryAgentSnapshot {
        let archive = try presentationSnapshot(history ?? context.state.history)
        let turns = ([archive.current] + archive.past).flatMap(\.turns)
        var tasks = (context.state.skillState?.tasks ?? []).reversed().map { task in
            var conversation = HistoryConversation()
            conversation.turns = turns
            var value = HistoryTask(
                id: task.id, title: task.goal, status: task.status,
                createdAt: task.date,
                turns: ConversationHistoryPresentation.turns(conversation).filter { $0.historyTaskID == task.id })
            value.compression = ([archive.current] + archive.past).flatMap(\.taskCompressions)
                .first { $0.taskID == task.id }
            value.resultText = value.compression?.text ?? task.summary
            value.execution = "foreground"
            value.executor = "assistant"
            value.skills = task.skills
            return value
        }
        for conversation in [archive.current] + archive.past {
            for compression in conversation.taskCompressions
            where !tasks.contains(where: { $0.id == compression.taskID }) {
                var task = HistoryTask(
                    id: compression.taskID, title: compression.goal, status: compression.status.rawValue,
                    createdAt: ConversationHistoryPresentation.turns(conversation).first(where: {
                        $0.historyTaskID == compression.taskID
                    })?.date,
                    turns: ConversationHistoryPresentation.turns(conversation).filter {
                        $0.historyTaskID == compression.taskID
                    })
                task.compression = compression
                task.resultText = compression.text
                task.execution = "foreground"
                task.executor = "assistant"
                tasks.append(task)
            }
        }
        for registered in context.tasks.records where registered.scope.execution == .background {
            let view = context.state.taskViews?[registered.scope.id]
            var task = HistoryTask(
                id: registered.scope.id, title: view?.goal ?? view?.text ?? "后台任务", status: registered.state.rawValue,
                createdAt: view?.createdAt, turns: [])
            task.skills = view?.skills ?? []
            task.resultText = view?.text
            task.execution = "background"
            task.executor = registered.scope.executor.rawValue
            task.parentTaskID = registered.scope.parentID
            tasks.append(task)
        }
        return HistoryAgentSnapshot(archive: archive, tasks: tasks)
    }
    public func showHistory(invocation: any FunctionInput) async throws {
        guard invocation.context.source == "memory", invocation.context.sessionID == sessionID else {
            throw HistoryIntentFailure.execution("Invalid history presentation scope")
        }
        try Task.checkCancellation()
        let presentation = try await Self.listPresentation(store)
        try Task.checkCancellation()
        state.archive = presentation
        state.status = await store.lastCheckpointError.map { "当前会话尚未保存：" + $0 }
    }
}
