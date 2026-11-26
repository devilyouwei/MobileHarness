import AgentCore
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

/// Optional execution time granted by the host for one active Writer segment.
public struct WriterBackgroundExecution: Sendable {
    public typealias Start =
        @MainActor @Sendable (
            _ expire: @escaping @Sendable () async -> Void,
            _ failed: @escaping @Sendable (String) async -> Void
        ) -> WriterBackgroundExecution?

    public let advance: @MainActor @Sendable () -> Void
    public let finish: @MainActor @Sendable (Bool) -> Void

    public init(
        advance: @escaping @MainActor @Sendable () -> Void, finish: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.advance = advance
        self.finish = finish
    }
}

/// Root-owned role lifecycle. It never shuts down the borrowed Gateway roots.
@MainActor public final class WriterContainer {
    private var agent: WriterAgent?
    private var executions: (any WriterExecutionRepository)?
    private var communications: (any AgentMessageRepository)?
    private var historyStore: WriterHistoryStore?
    private var manager: AgentManager?
    private var output: OutputGateway?
    private var registered = false
    private var closed = false
    private var startBackground: WriterBackgroundExecution.Start?
    /// Read model for the host records UI; available once storage is configured.
    public private(set) var records: WriterRecords?
    public init() {}
    public func bindBackgroundExecution(_ start: @escaping WriterBackgroundExecution.Start) {
        startBackground = start
    }
    func configureHistory(
        messages: any WriterMessageRepository, executions: any WriterExecutionRepository,
        communications: any AgentMessageRepository, logs: any ModelRequestLogRepository
    ) throws {
        guard historyStore == nil else { throw WriterFailure.unavailable }
        guard messages.storageScope == executions.storageScope, messages.storageScope == communications.storageScope
        else {
            throw RecordStorageError.invalidRecord
        }
        self.executions = executions
        self.communications = communications
        let historyStore = WriterHistoryStore(records: try WriterRecordStore(repository: messages, logs: logs))
        self.historyStore = historyStore
        records = WriterRecords(executions: executions, historyStore: historyStore)
    }
    func install(
        manager: AgentManager, output: OutputGateway, model: @escaping @Sendable () async throws -> ChatModel,
        streaming: any ArtifactStreaming, language: @escaping @Sendable () -> String
    ) throws {
        guard !closed, agent == nil, let historyStore, let executions, let communications else {
            throw WriterFailure.unavailable
        }
        agent = try WriterAgent(
            model: model, streaming: streaming, history: historyStore, executions: executions,
            communications: communications,
            startBackground: startBackground, language: language)
        records?.language = language
        self.manager = manager
        self.output = output
    }
    func start() async throws {
        guard !closed, let agent, let manager, let output else { throw WriterFailure.unavailable }
        if registered { return }
        try await manager.register(agent)
        registered = true
        do {
            await agent.bind(try await output.consumer(for: agent), messaging: try await output.messaging(for: .writer))
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
    func setSceneActive(_ active: Bool) async { await agent?.setSceneActive(active) }
    func beginModelChange() async { await agent?.beginModelChange() }
    func endModelChange() async { await agent?.endModelChange() }
    func setForeground(_ active: Bool) async throws {
        if active { try await agent?.resume() } else { try await agent?.pause() }
    }
    func stop() async throws {
        closed = true
        records?.close()
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
