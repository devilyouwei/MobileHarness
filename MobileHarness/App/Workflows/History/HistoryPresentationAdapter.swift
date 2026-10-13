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
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= ConversationHistoryStore.maximumBytes else {
            throw HistoryIntentFailure.execution("History snapshot exceeds limit")
        }
        return try JSONDecoder().decode(HistorySnapshot.self, from: data)
    }
    public static func assistantTasks(_ context: AgentContext<AssistantContextState>) throws -> HistoryAgentSnapshot {
        let archive = try presentationSnapshot(context.state.history)
        let turns = ([archive.current] + archive.past).flatMap(\.turns)
        var tasks = (context.state.skillState?.tasks ?? []).reversed().map { task in
            var conversation = HistoryConversation()
            let ids = Set(task.inputIDs)
            conversation.turns = turns.filter { ids.contains($0.id) }
            var value = HistoryTask(
                id: task.id, title: task.goal, status: task.status,
                createdAt: task.date, turns: ConversationHistoryPresentation.turns(conversation))
            value.resultText = task.summary
            value.execution = "foreground"
            value.executor = "assistant"
            value.skills = task.skills
            return value
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
        let snapshot = try await store.snapshot()
        try Task.checkCancellation()
        let presentation = try Self.presentationSnapshot(snapshot)
        state.archive = presentation
        state.status = nil
    }
}
