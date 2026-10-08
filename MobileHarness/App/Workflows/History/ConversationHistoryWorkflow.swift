import Foundation
import UI

/// One root-owned history operation slot. Cancel keeps admission closed until cleanup finishes.
@MainActor
public final class ConversationHistoryWorkflow: ConversationHistoryControlling {
    public let state: ConversationHistoryState
    private let deleteArchive: @MainActor (UUID) async throws -> Void
    private let refresh: @MainActor () async throws -> Void
    private let prepare: @MainActor () async throws -> Void
    private let startNewArchive: @MainActor () async throws -> Void
    private let summarizeArchive: @MainActor (UUID) async throws -> Void
    private let previewOutput: @MainActor (HistoryTurn) -> String
    private var loaded = false
    private var task: Task<Void, Never>?
    public init(
        state: ConversationHistoryState, prepare: @escaping @MainActor () async throws -> Void,
        refresh: @escaping @MainActor () async throws -> Void,
        deleteArchive: @escaping @MainActor (UUID) async throws -> Void,
        startNew: @escaping @MainActor () async throws -> Void,
        summarize: @escaping @MainActor (UUID) async throws -> Void,
        previewOutput: @escaping @MainActor (HistoryTurn) -> String
    ) {
        self.deleteArchive = deleteArchive
        self.refresh = refresh
        self.state = state
        self.prepare = prepare
        self.startNewArchive = startNew
        self.summarizeArchive = summarize
        self.previewOutput = previewOutput
    }
    public func load() async {
        guard !state.isBusy else { return }
        state.isBusy = true
        defer { state.isBusy = false }
        do {
            try await prepare()
            try Task.checkCancellation()
            try await refresh()
            loaded = true
            state.status = nil
        } catch { state.status = "历史读取失败：\(error)" }
    }
    public func startNew() {
        perform { try await self.startNewArchive() }
    }
    public func summarize(_ id: UUID) {
        perform { try await self.summarizeArchive(id) }
    }
    public func delete(_ id: UUID) {
        perform { try await self.deleteArchive(id) }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !state.isBusy, loaded else { return }
        state.isBusy = true
        task = Task {
            defer {
                state.isBusy = false
                task = nil
            }
            do { try await operation() } catch { state.status = "历史操作失败：\(error)" }
        }
    }
    public func cancel() { task?.cancel() }
    public func waitUntilIdle() async { await task?.value }
    public func preview(_ turn: HistoryTurn) -> String { previewOutput(turn) }
}
