import Foundation
import StorageChat
import UI

public enum HistoryImageLoadingError: Error { case invalidReference, busy, oversizedImage }

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
    private let readConversation: @MainActor (UUID) async throws -> HistoryConversation
    private let readPhoto: @MainActor (UUID, UUID) async throws -> Data?
    private var photoReads: Set<UUID> = []
    private var loaded = false
    private var task: Task<Void, Never>?
    public init(
        state: ConversationHistoryState, prepare: @escaping @MainActor () async throws -> Void,
        refresh: @escaping @MainActor () async throws -> Void,
        deleteArchive: @escaping @MainActor (UUID) async throws -> Void,
        startNew: @escaping @MainActor () async throws -> Void,
        summarize: @escaping @MainActor (UUID) async throws -> Void,
        previewOutput: @escaping @MainActor (HistoryTurn) -> String,
        readConversation: @escaping @MainActor (UUID) async throws -> HistoryConversation,
        readPhoto: @escaping @MainActor (UUID, UUID) async throws -> Data?
    ) {
        self.deleteArchive = deleteArchive
        self.refresh = refresh
        self.state = state
        self.prepare = prepare
        self.startNewArchive = startNew
        self.summarizeArchive = summarize
        self.previewOutput = previewOutput
        self.readPhoto = readPhoto
        self.readConversation = readConversation
    }
    public func load() async {
        guard !state.isBusy else { return }
        state.isBusy = true
        defer { state.isBusy = false }
        do {
            try await prepare()
            try Task.checkCancellation()
            state.status = nil
            try await refresh()
            loaded = true
        } catch { state.status = "历史读取失败：\(error)" }
    }
    public func loadConversation(_ id: UUID) async throws -> HistoryConversation {
        let selected = try await readConversation(id)
        guard selected.id == id else { throw HistoryDetailError.unavailable }
        state.selectedConversation = selected
        return selected
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
            do { try await operation() } catch ConversationHistoryError.busy {
                state.status = "正在回复或处理输入，请结束后再开始新对话。"
            } catch { state.status = "历史操作失败：\(error)" }
        }
    }
    public func cancel() { task?.cancel() }
    public func waitUntilIdle() async { await task?.value }
    public func imageData(_ id: UUID, for turnID: UUID) async throws -> Data? {
        try Task.checkCancellation()
        guard let archive = state.archive else { throw HistoryImageLoadingError.invalidReference }
        let selected = state.selectedConversation.flatMap { conversation in
            ([archive.current] + archive.past).contains(where: { $0.id == conversation.id }) ? conversation : nil
        }
        let turn = ([archive.current] + archive.past + [selected].compactMap { $0 }).lazy
            .flatMap { ConversationHistoryPresentation.turns($0) }.first { $0.id == turnID }
        guard let turn, turn.attachedImages.contains(where: { $0.id == id }) else {
            throw HistoryImageLoadingError.invalidReference
        }
        guard photoReads.count < 4 else { throw HistoryImageLoadingError.busy }
        let token = UUID()
        photoReads.insert(token)
        defer { photoReads.remove(token) }
        let data = try await readPhoto(id, turn.ownerInputID ?? turn.id)
        try Task.checkCancellation()
        guard data.map({ !$0.isEmpty && $0.count <= 4 * 1024 * 1024 }) ?? true else {
            throw HistoryImageLoadingError.oversizedImage
        }
        return data
    }
    public func preview(_ turn: HistoryTurn) -> String { previewOutput(turn) }
}
