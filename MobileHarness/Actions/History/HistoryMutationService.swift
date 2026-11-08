import Foundation
import FunctionContracts
import StorageChat
import StorageCore

/// Archive-only mutation validation; persistence remains an atomic Storage transaction.
public struct HistoryMutationService: HistoryMutationCapability {
    private let jobs = HistoryTitleJobs()
    private let archiveChanged: @Sendable (String?) async -> Void
    private let store: AssistantHistoryStore
    private let titlePositions: @Sendable (Int) -> [Int]
    private let summarizeTitle: @Sendable (AssistantConversation) async throws -> String
    public init(
        store: AssistantHistoryStore,
        summarizeTitle: @escaping @Sendable (AssistantConversation) async throws -> String,
        archiveChanged: @escaping @Sendable (String?) async -> Void = { _ in },
        titlePositions: @escaping @Sendable (Int) -> [Int] = { Array(0..<min(32, $0)) }
    ) {
        self.archiveChanged = archiveChanged
        self.titlePositions = titlePositions
        self.store = store
        self.summarizeTitle = summarizeTitle
    }
    public func clearRequestLogs(requestID: String?) async throws {
        try await store.clearRequestLogs(requestID: requestID)
    }
    public func startNew() async throws -> String? {
        try Task.checkCancellation()
        guard let archived = try await store.startNew() else { return nil }
        let accepted = await jobs.start {
            do {
                try await generateTitle(archived.id)
                await archiveChanged(nil)
            } catch { await archiveChanged("标题生成失败：\(error)") }
        }
        if !accepted {
            try await store.setTitle(nil, error: "Title worker busy; retry explicitly", for: archived.id)
        }
        return archived.id
    }
    public func waitForTitles() async { await jobs.wait() }
    public func shutdown() async { await jobs.stop() }
    public func summarizeArchived(_ id: String) async throws {
        guard await jobs.beginManual() else { throw AssistantHistoryError.busy }
        do {
            try await generateTitle(id)
            await jobs.endManual()
        } catch {
            await jobs.endManual()
            throw error
        }
    }
    private func generateTitle(_ id: String) async throws {
        try Task.checkCancellation()
        let snapshot = try await store.readCurrent()
        guard snapshot.current.id != id else { throw HistoryQueryError.currentConversation }
        let conversation: AssistantConversation
        do {
            let metadata = try await store.dialogMetadata(id)
            conversation = try await store.titleExcerpt(
                id, positions: titlePositions(metadata.turnCount ?? metadata.turns.count))
        } catch AssistantHistoryError.missingTurn {
            throw HistoryQueryError.missingConversation
        }
        do {
            try Task.checkCancellation()
            let title = try await summarizeTitle(conversation)
            try Task.checkCancellation()
            try await store.setTitle(title, for: id)
        } catch {
            let generationError = error
            do {
                // Retain retry evidence even when the caller cancelled; persistence joins before return.
                try await store.setTitle(nil, error: String(String(describing: generationError).prefix(1024)), for: id)
            } catch {
                let report = try ActionReport(entries: [
                    .init(
                        path: "title", status: generationError is CancellationError ? .cancelled : .failed,
                        code: ActionReport.code(for: generationError),
                        details: [
                            "failureDescription": String(ActionReport.description(for: generationError).prefix(128))
                        ]),
                    .init(
                        path: "retryState", status: .failed, code: ActionReport.code(for: error),
                        details: ["failureDescription": String(ActionReport.description(for: error).prefix(128))]),
                ])
                throw ActionReportedError(report)
            }
            throw generationError
        }
    }
    public func deleteArchived(_ id: String) async throws {
        try Task.checkCancellation()
        let snapshot = try await store.readCurrent()
        guard snapshot.current.id != id else { throw HistoryQueryError.currentConversation }
        do { _ = try await store.dialogMetadata(id) } catch AssistantHistoryError.missingTurn {
            throw HistoryQueryError.missingConversation
        }
        try Task.checkCancellation()
        try await store.deleteArchived(id)
    }

}

/// Exactly one root-owned title job; overflow is persisted as retryable title failure.
private actor HistoryTitleJobs {
    private var task: Task<Void, Never>?
    private var closed = false
    private var manual = false
    func start(_ operation: @escaping @Sendable () async -> Void) -> Bool {
        guard !closed, task == nil, !manual else { return false }
        task = Task {
            await operation()
            completed()
        }
        return true
    }
    func beginManual() -> Bool {
        guard !closed, task == nil, !manual else { return false }
        manual = true
        return true
    }
    func endManual() { manual = false }
    private func completed() { task = nil }
    func wait() async { await task?.value }
    func stop() async {
        closed = true
        let active = task
        active?.cancel()
        await active?.value
        task = nil
    }
}
