import Foundation
import PlatformKit
import StorageChat
import StorageCore
import UI

public enum HistoryImageLoadingError: Error { case invalidReference, busy, oversizedImage }

/// One root-owned history operation slot. Cancel keeps admission closed until cleanup finishes.
@MainActor
public final class ConversationHistoryWorkflow: ConversationHistoryControlling {
    public let state: any HistoryPresenting
    private let deleteArchive: @MainActor (String) async throws -> Void
    private let refresh: @MainActor () async throws -> Void
    private let prepare: @MainActor () async throws -> Void
    private let startNewArchive: @MainActor () async throws -> Void
    private let summarizeArchive: @MainActor (String) async throws -> Void
    private let previewOutput: @MainActor (HistoryTurn) -> String
    private let readConversation: @MainActor (String) async throws -> HistoryConversation
    private let readMessage: @MainActor (String) async throws -> HistoryConversation
    private let readPage: @MainActor (String, UInt64, String?) async throws -> HistoryConversation
    private let readArchives: @MainActor (Int64) async throws -> [HistoryConversation]
    private let readPhoto: @MainActor (String, String) async throws -> Data?
    private var photoReads: Set<UUID> = []
    private var detailTurns: [String: HistoryTurn] = [:]
    private var loaded = false
    private var task: Task<Void, Never>?
    private var archivePageTask: Task<Void, Never>?
    public init(
        state: any HistoryPresenting, prepare: @escaping @MainActor () async throws -> Void,
        refresh: @escaping @MainActor () async throws -> Void,
        deleteArchive: @escaping @MainActor (String) async throws -> Void,
        startNew: @escaping @MainActor () async throws -> Void,
        summarize: @escaping @MainActor (String) async throws -> Void,
        previewOutput: @escaping @MainActor (HistoryTurn) -> String,
        readConversation: @escaping @MainActor (String) async throws -> HistoryConversation,
        readPhoto: @escaping @MainActor (String, String) async throws -> Data?,
        readMessage: @escaping @MainActor (String) async throws -> HistoryConversation = { _ in
            throw HistoryDetailError.unavailable
        },
        readPage: @escaping @MainActor (String, UInt64, String?) async throws -> HistoryConversation = { _, _, _ in
            throw HistoryDetailError.unavailable
        },
        readArchives: @escaping @MainActor (Int64) async throws -> [HistoryConversation] = { _ in
            throw HistoryDetailError.unavailable
        }
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
        self.readMessage = readMessage
        self.readPage = readPage
        self.readArchives = readArchives
    }
    public func load() async {
        guard !state.isRefreshing, !state.isBusy || archivePageTask != nil else { return }
        state.present(.isRefreshing(true))
        defer { state.present(.isRefreshing(false)) }
        if let archivePageTask {
            archivePageTask.cancel()
            await archivePageTask.value
        }
        guard !Task.isCancelled else { return }
        state.present(.isBusy(true))
        defer { state.present(.isBusy(false)) }
        do {
            try await prepare()
            try Task.checkCancellation()
            state.present(.status(nil))
            try await refresh()
            state.present(.hasMoreArchives(state.archive?.past.count == HistoryPaging.pageSize))
            state.present(.archivePaging(.init()))
            loaded = true
        } catch { state.present(.status("历史读取失败：\(error)")) }
    }
    public func loadConversation(_ id: String) async throws -> HistoryConversation {
        guard let recordID = BusinessRecordID(rawValue: id), recordID.kind == .dialog else {
            throw HistoryDetailError.unavailable
        }
        let selected = try await readConversation(recordID.rawValue)
        guard selected.id == id else { throw HistoryDetailError.unavailable }
        state.present(.selectedConversation(selected))
        detailTurns.removeAll()
        return selected
    }
    public func loadConversation(_ id: String, after: UInt64, taskID: String?) async throws -> HistoryConversation {
        try await readPage(id, after, taskID)
    }
    public func loadMessage(_ turn: HistoryTurn) async throws -> HistoryTurn {
        guard let id = turn.messageID else { return turn }
        let conversation = try await readMessage(id)
        guard let result = ConversationHistoryPresentation.turns(conversation).first else {
            throw HistoryDetailError.unavailable
        }
        if detailTurns.count >= 4, let first = detailTurns.keys.sorted().first { detailTurns[first] = nil }
        detailTurns[result.id] = result
        return result
    }
    public func loadMoreArchives(retry: Bool) async {
        guard !Task.isCancelled, !state.isRefreshing, !state.isBusy, state.hasMoreArchives,
            let id = state.archive?.past.last?.id,
            let cursor = BusinessRecordID(rawValue: id)?.number,
            let ticket = state.beginArchivePage(after: id, retry: retry)
        else { return }
        state.present(.isBusy(true))
        let worker = Task {
            defer {
                state.present(.isBusy(false))
                archivePageTask = nil
            }
            await loadArchivePage(after: cursor, id: id, ticket: ticket)
        }
        archivePageTask = worker
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    private func loadArchivePage(after cursor: Int64, id: String, ticket: UUID) async {
        do {
            try Task.checkCancellation()
            let page = try await readArchives(cursor)
            try Task.checkCancellation()
            guard state.archivePaging.accepts(ticket) else { return }
            guard state.archive?.past.last?.id == id else {
                state.cancelArchivePage(ticket)
                return
            }
            guard page.count <= HistoryPaging.pageSize,
                page.allSatisfy({
                    guard let key = BusinessRecordID(rawValue: $0.id), key.kind == .dialog else { return false }
                    return key.number < cursor
                })
            else { throw HistoryDetailError.unavailable }
            state.appendArchives(page)
            state.present(.hasMoreArchives(page.count == HistoryPaging.pageSize))
            state.finishArchivePage(ticket)
        } catch is CancellationError {
            state.cancelArchivePage(ticket)
        } catch {
            if Task.isCancelled {
                state.cancelArchivePage(ticket)
            } else {
                state.finishArchivePage(ticket, error: "读取失败：\(error)")
            }
        }
    }
    public func startNew() {
        perform { try await self.startNewArchive() }
    }
    public func summarize(_ id: String) {
        perform {
            guard let recordID = BusinessRecordID(rawValue: id), recordID.kind == .dialog else {
                throw HistoryDetailError.unavailable
            }
            try await self.summarizeArchive(recordID.rawValue)
        }
    }
    public func delete(_ id: String) {
        perform {
            guard let recordID = BusinessRecordID(rawValue: id), recordID.kind == .dialog else {
                throw HistoryDetailError.unavailable
            }
            try await self.deleteArchive(recordID.rawValue)
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !state.isRefreshing, !state.isBusy, loaded else { return }
        state.present(.isBusy(true))
        task = Task {
            defer {
                state.present(.isBusy(false))
                task = nil
            }
            do { try await operation() } catch ConversationHistoryError.busy {
                state.present(.status("正在回复或处理输入，请结束后再开始新对话。"))
            } catch { state.present(.status("历史操作失败：\(error)")) }
        }
    }
    public func cancel() { task?.cancel() }
    public func waitUntilIdle() async { await task?.value }
    public func imageData(_ id: String, for turnID: String) async throws -> Data? {
        try Task.checkCancellation()
        guard let archive = state.archive else { throw HistoryImageLoadingError.invalidReference }
        let selected = state.selectedConversation.flatMap { conversation in
            ([archive.current] + archive.past).contains(where: { $0.id == conversation.id }) ? conversation : nil
        }
        let turn =
            detailTurns[turnID]
            ?? ([archive.current] + archive.past + [selected].compactMap { $0 }).lazy
            .flatMap { ConversationHistoryPresentation.turns($0) }.first { $0.id == turnID }
        guard let turn, turn.attachedImages.contains(where: { $0.id == id }) else {
            throw HistoryImageLoadingError.invalidReference
        }
        guard photoReads.count < 4 else { throw HistoryImageLoadingError.busy }
        let token = UUID()
        photoReads.insert(token)
        defer { photoReads.remove(token) }
        guard let mediaID = BusinessRecordID(rawValue: id), mediaID.kind == .media,
            let inputID = UUID(uuidString: turn.ownerInputID ?? turn.id)
        else { throw HistoryImageLoadingError.invalidReference }
        let data = try await readPhoto(mediaID.rawValue, inputID.uuidString)
        try Task.checkCancellation()
        guard data.map({ !$0.isEmpty && $0.count <= 4 * 1024 * 1024 }) ?? true else {
            throw HistoryImageLoadingError.oversizedImage
        }
        return data
    }
    public func preview(_ turn: HistoryTurn) -> String { previewOutput(turn) }
}
