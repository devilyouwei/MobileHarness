import Foundation
import StorageChat
import UI

/// One root-owned history operation slot. Cancel keeps admission closed until cleanup finishes.
@MainActor
public final class ConversationHistoryWorkflow: ConversationHistoryControlling {
    public let state: ConversationHistoryState
    private let deleteArchive: @MainActor (UUID) async throws -> Void
    private let refresh: @MainActor () async throws -> Void
    private let loadStore: @MainActor () async throws -> ConversationHistoryStore
    private let summarizeTitle: @MainActor (StoredConversation) async throws -> String
    private let previewOutput: @MainActor (ConversationRecord) -> String
    private var store: ConversationHistoryStore?
    private var task: Task<Void, Never>?
    public init(
        state: ConversationHistoryState, loadStore: @escaping @MainActor () async throws -> ConversationHistoryStore,
        refresh: @escaping @MainActor () async throws -> Void,
        deleteArchive: @escaping @MainActor (UUID) async throws -> Void,
        summarizeTitle: @escaping @MainActor (StoredConversation) async throws -> String,
        previewOutput: @escaping @MainActor (ConversationRecord) -> String
    ) {
        self.deleteArchive = deleteArchive
        self.refresh = refresh
        self.state = state
        self.loadStore = loadStore
        self.summarizeTitle = summarizeTitle
        self.previewOutput = previewOutput
    }
    public func load() async {
        guard !state.isBusy else { return }
        state.isBusy = true
        defer { state.isBusy = false }
        do {
            let loaded = try await loadStore()
            try Task.checkCancellation()
            store = loaded
            try await refresh()
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
        perform { _ in
            do {
                try await self.deleteArchive(id)
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
            let title = try await summarizeTitle(conversation)
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
    public func preview(_ turn: ConversationRecord) -> String { previewOutput(turn) }
}
