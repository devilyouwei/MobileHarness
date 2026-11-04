import AgentCore
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageChat
import StorageCore
import StorageMedia
import StorageTasks
import UI

/// Root-owned role lifecycle. It never shuts down the borrowed Gateway roots.
@MainActor public final class WriterContainer {
    private var agent: WriterAgent?
    private var tasks: (any TaskRepository)?
    private var photos: CapturedPhotoStore?
    public func bindPhotos(_ photos: CapturedPhotoStore?) { self.photos = photos }
    public func historyImage(_ id: String, input: String) async throws -> Data? {
        guard !closed, let photos else { throw WriterFailure.unavailable }
        return try await photos.readForInput(id, source: "writer", input: input)
    }
    private var manager: AgentManager?
    private var output: OutputGateway?
    private var registered = false
    private var closed = false
    public private(set) var artifacts: (any WriterArtifactsControlling)?
    public func bindArtifacts(_ artifacts: (any WriterArtifactsControlling)?) { self.artifacts = artifacts }
    public private(set) var historyStore: ConversationHistoryStore?
    public init() {}
    func configureHistory(chat: any ChatRepository, tasks: any TaskRepository) throws {
        guard historyStore == nil else { throw WriterFailure.unavailable }
        self.tasks = tasks
        historyStore = ConversationHistoryStore(
            records: try ConversationRecordStore(repository: chat, tasks: tasks, agent: "writer"))
    }
    func install(
        manager: AgentManager, output: OutputGateway, model: @escaping @Sendable () async throws -> ChatModel,
        streaming: any ArtifactStreaming
    ) throws {
        guard !closed, agent == nil, let historyStore, let tasks else { throw WriterFailure.unavailable }
        agent = try WriterAgent(model: model, streaming: streaming, history: historyStore, photos: photos, tasks: tasks)
        self.manager = manager
        self.output = output
    }
    func start() async throws {
        guard !closed, let agent, let manager, let output else { throw WriterFailure.unavailable }
        if registered { return }
        try await manager.register(agent)
        registered = true
        do {
            await agent.bind(try await output.consumer(for: agent))
            try await manager.start(.writer)
        } catch {
            let primary = error
            do {
                try await manager.remove(.writer)
                registered = false
            } catch { throw WriterCleanupFailure(primary: primary, cleanup: error) }
            throw primary
        }
    }
    func setForeground(_ active: Bool) async throws {
        if active { try await agent?.resume() } else { try await agent?.pause() }
    }
    func stop() async throws {
        closed = true
        if registered {
            try await manager?.remove(.writer)
            registered = false
        }
    }
    public func stateSnapshot() async throws -> AgentStateSnapshot {
        if let agent { return await agent.observationSnapshot() }
        return .init(path: "agents.writer", runtime: ["installed": .flag(false)])
    }
}

extension WriterContainer: WriterRecordsControlling {
    public func tasks(before: String?) async throws -> [WriterTaskItem] {
        guard !closed, let tasks else { throw WriterFailure.unavailable }
        let cursor = try before.map { try BusinessRecordID.number($0, kind: .task) }
        var values: [WriterTaskItem] = []
        for record in try await tasks.delegatedTasks(agent: "writer", before: cursor, limit: 20) {
            values.append(try await enrichedItem(record))
        }
        return values
    }
    private static func item(_ record: DelegatedTaskRecord) -> WriterTaskItem {
        var value = WriterTaskItem(
            id: record.id, dialogID: record.dialogID, goal: record.goal, projectID: record.projectID,
            runID: record.runID, status: record.status, failure: record.failure, updatedAt: record.updatedAt)
        value.phase = record.phase
        return value
    }
    private func enrichedItem(_ record: DelegatedTaskRecord) async throws -> WriterTaskItem {
        guard let historyStore else { throw WriterFailure.unavailable }
        var item = Self.item(record)
        item.startedAt = try await historyStore.dialogMetadata(record.dialogID).createdAt
        item.requestCount = try await historyStore.requestCount(record.dialogID)
        return item
    }
    public func task(_ id: String) async throws -> WriterTaskItem {
        guard !closed, let tasks else { throw WriterFailure.unavailable }
        let record = try await tasks.delegatedTask(id, agent: "writer")
        return try await enrichedItem(record)
    }
    public func requests(taskID: String, after: UInt64) async throws -> WriterRequestPage {
        guard !closed, let tasks, let historyStore else { throw WriterFailure.unavailable }
        let record = try await tasks.delegatedTask(taskID, agent: "writer")
        let rows = try await historyStore.requestPreviews(record.dialogID, after: after)
        let items = rows.map { row in
            WriterRequestItem(
                id: row.id, position: row.position, number: row.ordinal, runID: row.metadata["runID"] ?? record.runID,
                phase: row.metadata["phase"] ?? "模型请求", path: row.metadata["path"],
                attempt: Int(row.metadata["attempt"] ?? "1") ?? 1,
                date: row.date, state: row.metadata["toolsPending"] == "true" ? "executing" : row.state)
        }
        return .init(items: items, nextPosition: rows.count == 20 ? rows.last?.position : nil)
    }
    public func message(_ id: String) async throws -> HistoryConversation {
        guard !closed, let historyStore else { throw WriterFailure.unavailable }
        return try JSONDecoder().decode(
            HistoryConversation.self, from: JSONEncoder().encode(try await historyStore.message(id)))
    }
    public func imageData(_ id: String, input: String) async throws -> Data? {
        try await historyImage(id, input: input)
    }
    public func shareTask(_ id: String) async throws -> String {
        guard !closed, let tasks, let historyStore else { throw WriterFailure.unavailable }
        let item = try await task(id)
        let runs = try await tasks.delegatedRuns(id, agent: "writer")
        var after: UInt64 = 0
        var messages: [StoredConversation] = []
        var bytes = 0
        repeat {
            let page = try await historyStore.page(item.dialogID, after: after)
            for turn in page.turns {
                try Task.checkCancellation()
                guard let message = turn.modelRequests?.first?.messageID ?? turn.messageID else { continue }
                let full = try await historyStore.message(message)
                bytes += try JSONEncoder().encode(full).count
                guard bytes <= 32 * 1024 * 1024 else { throw WriterFailure.capacity }
                messages.append(full)
            }
            guard let next = page.nextPosition else { break }
            guard next > after else { throw WriterFailure.invalidOutput }
            after = next
        } while true
        struct Export: Encodable {
            let task: WriterTaskItem
            let runs: [DelegatedRunRecord]
            let messages: [StoredConversation]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Export(task: item, runs: runs, messages: messages))
        guard data.count <= 32 * 1024 * 1024 else { throw WriterFailure.capacity }
        return String(decoding: data, as: UTF8.self)
    }
}
