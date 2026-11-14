import Foundation
import FunctionContracts
import OSLog
import PlatformKit
import StorageChat
import StorageCore
import UI

public enum HistoryImageLoadingError: Error { case invalidReference, busy }

/// One root-owned history operation slot. Cancel keeps admission closed until cleanup finishes.
@MainActor
public final class ConversationHistoryWorkflow: ConversationHistoryControlling {
    private let log = Logger(subsystem: "dev.mobileharness", category: "history")
    public let state: any HistoryPresenting
    private let clearLogs: @MainActor (String?) async throws -> Void
    private let deleteArchive: @MainActor (String) async throws -> Void
    private let refresh: @MainActor () async throws -> Void
    private let prepare: @MainActor () async throws -> Void
    private let startNewArchive: @MainActor () async throws -> Void
    private let summarizeArchive: @MainActor (String) async throws -> Void
    private let readConversation: @MainActor (String) async throws -> HistoryConversation
    private let readMessage: @MainActor (String) async throws -> HistoryConversation
    private let readPage: @MainActor (String, UInt64, String?) async throws -> HistoryConversation
    private let readArchives: @MainActor (Int64) async throws -> [HistoryConversation]
    private var detailTurns: [String: HistoryTurn] = [:]
    private var loaded = false
    private var stopped = false
    private var task: Task<Void, Never>?
    private var archivePageTask: Task<Void, Never>?
    public init(
        state: any HistoryPresenting,
        clearLogs: @escaping @MainActor (String?) async throws -> Void = { _ in throw HistoryDetailError.unavailable },
        prepare: @escaping @MainActor () async throws -> Void,
        refresh: @escaping @MainActor () async throws -> Void,
        deleteArchive: @escaping @MainActor (String) async throws -> Void,
        startNew: @escaping @MainActor () async throws -> Void,
        summarize: @escaping @MainActor (String) async throws -> Void,
        readConversation: @escaping @MainActor (String) async throws -> HistoryConversation,
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
        self.clearLogs = clearLogs
        self.deleteArchive = deleteArchive
        self.refresh = refresh
        self.state = state
        self.prepare = prepare
        self.startNewArchive = startNew
        self.summarizeArchive = summarize
        self.readConversation = readConversation
        self.readMessage = readMessage
        self.readPage = readPage
        self.readArchives = readArchives
    }
    public func load() async {
        guard !stopped, !state.isRefreshing, !state.isBusy || archivePageTask != nil else { return }
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
        } catch {
            log.error("History load failed: \(String(describing: error), privacy: .private)")
            state.present(.status("Could not load conversation history."))
        }
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
        guard !stopped, !Task.isCancelled, !state.isRefreshing, !state.isBusy, state.hasMoreArchives,
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
                state.finishArchivePage(ticket, error: "Could not load history: \(error)")
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
        guard !stopped, !state.isRefreshing, !state.isBusy, loaded else { return }
        state.present(.isBusy(true))
        task = Task {
            defer {
                state.present(.isBusy(false))
                task = nil
            }
            do { try await operation() } catch AssistantHistoryError.busy {
                state.present(
                    .status("Wait for the current reply or input to finish before starting a new conversation."))
            } catch {
                log.error("History operation failed: \(String(describing: error), privacy: .private)")
                state.present(.status("History operation failed. Try again."))
            }
        }
    }
    public func shutdown() async {
        stopped = true
        task?.cancel()
        archivePageTask?.cancel()
        await task?.value
        await archivePageTask?.value
    }
    public func cancel() { task?.cancel() }
    public func waitUntilIdle() async { await task?.value }
    public func clearRequestLogs(requestID: String?) async throws {
        guard !stopped, !state.isBusy else { throw HistoryImageLoadingError.busy }
        try await clearLogs(requestID)
        detailTurns.removeAll()
        try await refresh()
    }
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
        if let data = HistoryRecordedImages.data(id, json: turn.requestParametersJSON) { return data }
        throw HistoryImageAvailabilityError.expired
    }
}

extension ConversationHistoryWorkflow {
    /// Reuses the same paged history presentation for a separately scoped Agent repository.
    @MainActor public static func records(
        store: AssistantHistoryStore, state: ConversationHistoryState,
        mutate: @escaping @MainActor (String, String?) async throws -> Void
    )
        -> ConversationHistoryWorkflow
    {
        let refresh: @MainActor () async throws -> Void = {
            let snapshot = try await HistoryPresentationAdapter.listPresentation(store)
            try state.requirePresentation()
            state.present(snapshot, status: nil)
        }
        return ConversationHistoryWorkflow(
            state: state, clearLogs: { try await mutate("clearLogs", $0) }, prepare: {}, refresh: refresh,
            deleteArchive: { id in
                try await mutate("delete", id)
                try await refresh()
            },
            startNew: {
                try await mutate("startNew", nil)
                try await refresh()
            },
            summarize: { id in
                try await mutate("title", id)
                try await refresh()
            },
            readConversation: { try await HistoryPresentationAdapter.conversation(store.page($0)) },
            readMessage: { try await HistoryPresentationAdapter.conversation(store.message($0)) },
            readPage: { try await HistoryPresentationAdapter.conversation(store.page($0, after: $1, taskID: $2)) },
            readArchives: { cursor in
                try await store.archivePage(before: cursor).map { try HistoryPresentationAdapter.conversation($0) }
            })
    }
}
