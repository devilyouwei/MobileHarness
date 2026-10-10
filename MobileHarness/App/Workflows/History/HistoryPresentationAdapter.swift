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
    public init(state: ConversationHistoryState, store: ConversationHistoryStore, sessionID: UUID) {
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
    public static func taskSnapshot<State: AgentChatContextState>(_ context: AgentContext<State>) throws
        -> HistoryAgentSnapshot
    {
        let archive = try presentationSnapshot(context.state.history)
        let rawTurns = ([archive.current] + archive.past).flatMap(\.turns)
        var members: [UUID: UUID] = [:]
        var dates: [UUID: Date] = [:]
        var titles: [UUID: String] = [:]
        for record in context.records {
            guard let evidence = try? JSONDecoder().decode(SignalEvidence.self, from: record.data)
            else { continue }
            let signal =
                evidence.contract.hasPrefix("task.")
                ? evidence.content.flatMap { try? JSONDecoder().decode(AgentTaskSignal.self, from: $0) } : nil
            guard let taskID = signal?.scope.id ?? record.taskID else { continue }
            members[evidence.signalID] = taskID
            dates[taskID] = min(dates[taskID] ?? record.date, record.date)
            if evidence.contract == "task.request", let signal,
                signal.scope.executor == context.agentID,
                let content = try? AgentTaskContent.decode(signal)
            {
                titles[taskID] = content.text
            }
        }
        let views = (context.state.taskViews ?? [:]).filter { $0.value.scope.executor == context.agentID }
        let grouped = Dictionary(grouping: rawTurns) { members[$0.id] ?? $0.id }
        let ids = Set(grouped.keys).union(views.keys)
        let tasks = ids.map { id -> HistoryTask in
            let stored = (grouped[id] ?? []).sorted { $0.date < $1.date }
            let registered = context.tasks.task(id)
            let associated = views[id] != nil || registered != nil || stored.contains { members[$0.id] != nil }
            var conversation = HistoryConversation()
            conversation.turns = stored
            let state =
                registered?.state.rawValue ?? context.work[id]?.state.rawValue
                ?? stored.last?.state.rawValue ?? "unknown"
            let status: String
            if views[id]?.stage == .waitingUser, views[id]?.terminal == false,
                !["succeeded", "completed", "failed", "cancelled", "interrupted"].contains(state)
            {
                status = "等待用户"
            } else {
                switch state {
                case "requested", "accepted", "queued": status = "待处理"
                case "running", "generating", "awaitingFeedback", "continuation": status = "进行中"
                case "cancelling": status = "取消中"
                case "succeeded", "completed": status = "已完成"
                case "failed": status = "失败"
                case "cancelled": status = "已取消"
                case "interrupted": status = "已中断"
                default: status = ""
                }
            }
            let initialInput = stored.first?.user ?? views[id]?.text ?? "任务"
            let title = titles[id] ?? initialInput
            let date: Date? = dates[id] ?? stored.first?.date
            let turns = ConversationHistoryPresentation.turns(conversation)
            return HistoryTask(
                id: id, title: title, status: status, createdAt: date,
                isAssociated: associated, turns: turns)
        }.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString : ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
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
        state.archive = try Self.presentationSnapshot(snapshot)
        state.status = nil
    }
}
