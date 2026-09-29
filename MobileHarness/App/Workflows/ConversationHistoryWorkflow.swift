import AgentCore
import Agents
import Foundation
import ModelKit
import Storage
import UI

/// One root-owned history operation slot. Cancel keeps admission closed until cleanup finishes.
@MainActor
public final class ConversationHistoryWorkflow: ConversationHistoryControlling {
    public let state: ConversationHistoryState
    private let loadStore: @MainActor () async throws -> ConversationHistoryStore
    private let makeChat: @MainActor () async throws -> any ChatCapability
    private var store: ConversationHistoryStore?
    private var task: Task<Void, Never>?
    public init(
        state: ConversationHistoryState, loadStore: @escaping @MainActor () async throws -> ConversationHistoryStore,
        makeChat: @escaping @MainActor () async throws -> any ChatCapability
    ) {
        self.state = state
        self.loadStore = loadStore
        self.makeChat = makeChat
    }
    public func load() async {
        guard !state.isBusy else { return }
        state.isBusy = true
        defer { state.isBusy = false }
        do {
            let loaded = try await loadStore()
            try Task.checkCancellation()
            store = loaded
            state.archive = try await loaded.snapshot()
            state.status = nil
        } catch { state.status = "历史读取失败：\(error)" }
    }
    public func startNew() {
        perform { store in
            do {
                guard let previous = try await store.startNew() else { return }
                self.state.archive = try await store.snapshot()
                self.state.status = "新对话已开始，正在为上一段对话生成标题…"
                await self.generateTitle(previous, store: store)
            } catch { self.state.status = "创建新对话失败：\(error)" }
        }
    }
    public func summarize(_ id: UUID) {
        perform { store in
            do {
                guard let conversation = try await store.snapshot().past.first(where: { $0.id == id }) else { return }
                await self.generateTitle(conversation, store: store)
            } catch { self.state.status = "读取历史失败：\(error)" }
        }
    }
    public func delete(_ id: UUID) {
        perform { store in
            do {
                try await store.deleteArchived(id)
                self.state.archive = try await store.snapshot()
            } catch { self.state.status = "删除失败：\(error)" }
        }
    }
    private func perform(_ operation: @escaping @MainActor (ConversationHistoryStore) async -> Void) {
        guard !state.isBusy, let store else { return }
        state.isBusy = true
        task = Task {
            defer {
                state.isBusy = false
                task = nil
            }
            await operation(store)
        }
    }
    public func cancel() { task?.cancel() }
    public func waitUntilIdle() async { await task?.value }
    private func generateTitle(_ conversation: StoredConversation, store: ConversationHistoryStore) async {
        do {
            try Task.checkCancellation()
            let chat = try await makeChat()
            try Task.checkCancellation()
            let title = try await ConversationTitleGenerator.summarize(conversation, using: chat)
            try Task.checkCancellation()
            try await store.setTitle(title, for: conversation.id)
            state.status = "历史标题已保存。"
        } catch {
            do {
                try await store.setTitle(nil, error: String(describing: error), for: conversation.id)
                state.status = "会话已归档，标题尚未生成，可稍后重试。"
            } catch { state.status = "保存标题状态失败：\(error)" }
        }
        do { state.archive = try await store.snapshot() } catch { state.status = "刷新历史失败：\(error)" }
    }
    public func preview(_ turn: ConversationRecord) -> String {
        do {
            let configuration = try AgentConfigurations.load(named: "Assistant")
            var trace = try GenerationTrace(
                capabilities: AssistantAgent.runtimeCapabilities(configuration.capabilities),
                textMapping: AssistantAgent.mapText)
            for delta in turn.fragments { try trace.append(delta) }
            if turn.finishReason != nil { trace.finish() }
            var depth = 0
            let lines = trace.events.enumerated().map { index, event in
                if case .scheduling(.endWait) = event { depth = max(0, depth - 1) }
                let prefix = "\(index + 1). " + String(repeating: "  ", count: depth)
                switch event {
                case .scheduling(.beginWait):
                    depth += 1
                    return prefix + "<wait>"
                case .scheduling(.endWait): return prefix + "</wait>"
                case .action(let call): return prefix + "[\(call.channel)] \(call.actionPath) \(call.parameters)"
                }
            }
            return ([trace.parserError ?? "已接收内容的解析结果；不代表实际执行顺序。"] + lines).joined(separator: "\n")
        } catch { return "预览失败：\(error)" }
    }
}
