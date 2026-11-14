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
    private var manager: AgentManager?
    private var output: OutputGateway?
    private var registered = false
    private var closed = false
    private var startBackground: WriterBackgroundExecution.Start?
    public private(set) var artifacts: (any WriterArtifactsControlling)?
    public func bindArtifacts(_ artifacts: (any WriterArtifactsControlling)?) { self.artifacts = artifacts }
    public private(set) var historyStore: WriterHistoryStore?
    private var language: @Sendable () -> String = { "en" }
    private var copy: AppLanguage { AppLanguage(preferredLanguage: language()) }
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
        historyStore = WriterHistoryStore(
            records: try WriterRecordStore(repository: messages, logs: logs))
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
        self.language = language
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
    public func clearRequestLogs(requestID: String?) async throws {
        guard !closed, let historyStore else { throw WriterFailure.unavailable }
        try await historyStore.clearRequestLogs(requestID: requestID)
    }
    private func delegationItem(_ row: WriterRequestRecord) async throws -> WriterDelegationItem {
        var linkedWorkspace: WriterWorkspaceItem?
        if !row.workspaceID.isEmpty { linkedWorkspace = try await workspace(row.workspaceID) }
        var result: String?
        if let raw = row.result,
            let completion = try? JSONDecoder().decode(AgentTaskResponse.self, from: Data(raw.utf8)),
            let signal = completion.signal
        {
            result = try AgentTaskContent.decode(signal).text
        }
        let failure = row.failure.flatMap { raw in
            (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)))?["message"] ?? raw
        }
        var item = WriterDelegationItem(
            id: row.id, position: row.messageID, goal: row.goal, input: row.input, sourceAgent: row.sourceAgent,
            sourceContext: row.sourceContext, date: row.createdAt,
            state: ["closing", "cleanup_failed", "waiting_input", "paused"].contains(row.executionState)
                ? row.executionState : row.status, result: result,
            failure: failure, workspace: linkedWorkspace)
        if let raw = row.waiting {
            item.waiting = try JSONDecoder().decode(AgentTaskContent.self, from: Data(raw.utf8)).text
        }
        return item
    }
    public func delegations(before: UInt64?) async throws -> WriterDelegationPage {
        guard !closed, let executions else { throw WriterFailure.unavailable }
        let rows = try await executions.delegations(before: before, limit: 21)
        var items: [WriterDelegationItem] = []
        for row in rows.prefix(20) { items.append(try await delegationItem(row)) }
        return .init(
            items: items, next: rows.count > 20 ? items.last?.position : nil,
            total: try await executions.delegationCount())
    }
    public func delegation(_ id: String) async throws -> WriterDelegationItem {
        guard !closed, let executions else { throw WriterFailure.unavailable }
        return try await delegationItem(executions.request(id, agent: "writer"))
    }
    public func preflight(_ id: String, after: UInt64) async throws -> WriterRequestPage {
        guard !closed, let executions, let historyStore else { throw WriterFailure.unavailable }
        let request = try await executions.request(id, agent: "writer")
        let rows = try await historyStore.requestPreviews(
            "writer/preflight_" + String(request.messageID), after: after, limit: 21)
        return messagePage(rows)
    }
    private func messagePage(_ rows: [WriterMessagePreview]) -> WriterRequestPage {
        let copy = copy
        let items = rows.prefix(20).map { row in
            let label = WriterRequestNaming.summary(
                phase: row.metadata["phase"] ?? "Follow-up input", path: row.metadata["path"], calls: row.toolCalls,
                domain: row.metadata["controlDomain"], language: copy)
            return WriterRequestItem(
                id: row.id, position: row.position, number: row.ordinal, delegateID: row.metadata["delegateID"] ?? "",
                phase: copy.text(WriterRequestNaming.phase(row.metadata["phase"] ?? "Follow-up input")),
                path: row.metadata["path"],
                attempt: Int(row.metadata["attempt"] ?? "1") ?? 1, date: row.date,
                state: WriterRequestNaming.state(
                    request: row.state, calls: row.toolCalls, pending: row.metadata["toolsPending"] == "true"),
                title: label)
        }
        return .init(items: items, nextPosition: rows.count > 20 ? items.last?.position : nil)
    }
    public func workspaces(before: String?) async throws -> WriterWorkspacePage {
        guard !closed, let executions else { throw WriterFailure.unavailable }
        let cursor = try before.map { try BusinessRecordID.number($0, kind: .workspace) }
        var values: [WriterWorkspaceItem] = []
        let rows = try await executions.workspaces(agent: "writer", before: cursor, limit: 21)
        for record in rows.prefix(20) {
            values.append(try await enrichedItem(record))
        }
        return .init(items: values, nextID: rows.count > 20 ? values.last?.id : nil)
    }
    private static func item(_ record: WriterWorkspaceRecord) -> WriterWorkspaceItem {
        WriterWorkspaceItem(
            workspaceID: record.workspaceID, title: record.title,
            updatedAt: record.updatedAt)
    }
    private func enrichedItem(_ record: WriterWorkspaceRecord) async throws -> WriterWorkspaceItem {
        guard let historyStore else { throw WriterFailure.unavailable }
        var item = Self.item(record)
        item.isDeleted = record.status == "deleted"
        item.startedAt = try await historyStore.ownerMetadata(record.workspaceID).createdAt
        item.requestCount = try await historyStore.requestCount(record.workspaceID)
        return item
    }
    public func workspace(_ id: String) async throws -> WriterWorkspaceItem {
        guard !closed, let executions else { throw WriterFailure.unavailable }
        let record = try await executions.workspace(id, agent: "writer")
        return try await enrichedItem(record)
    }
    public func requests(workspaceID: String, after: UInt64) async throws -> WriterRequestPage {
        guard !closed, let executions, let historyStore else { throw WriterFailure.unavailable }
        let record = try await executions.workspace(workspaceID, agent: "writer")
        let rows = try await historyStore.requestPreviews(record.workspaceID, after: after, limit: 21)
        return messagePage(rows)
    }
    public func requests(workspaceID: String, before: UInt64?) async throws -> WriterRequestPage {
        guard !closed, let historyStore else { throw WriterFailure.unavailable }
        guard WorkspaceID(rawValue: workspaceID) != nil else { throw RecordStorageError.invalidID }
        let rows = try await historyStore.requestPreviews(workspaceID, before: before, limit: 21)
        return messagePage(rows)
    }
    public func requestDetail(_ id: String) async throws -> WriterRequestDetails {
        guard !closed, let historyStore else { throw WriterFailure.unavailable }
        guard let turn = try await historyStore.message(id).turns.first,
            var selected = turn.modelRequests?.first
        else { throw WriterHistoryError.missingTurn }
        selected.responseEventsJSON = nil
        let request =
            BusinessRecordID(rawValue: id)?.kind == .request
            ? try JSONDecoder().decode(HistoryModelRequest.self, from: JSONEncoder().encode(selected)) : nil
        let inputs = request.map(WriterRecordPresentation.requestInputs) ?? []
        let context = try await historyStore.detailContext(id, toolCallIDs: inputs.compactMap(\.toolCallID))
        let calls = selected.toolCalls.map {
            WriterToolPreview(name: $0.name, argumentsJSON: $0.argumentsJSON, state: $0.state.rawValue)
        }
        let metadata = selected.producerMetadata
        let phase =
            metadata?["phase"] ?? selected.decisionMetadata?.mode ?? (request == nil ? "Input" : "Model request")
        let path = metadata?["path"]
        let summary = WriterRequestItem(
            id: id, position: selected.historyOrder, number: context.ordinal,
            delegateID: selected.decisionMetadata?.delegateID ?? "", phase: copy.text(WriterRequestNaming.phase(phase)),
            path: path,
            attempt: Int(metadata?["attempt"] ?? "1") ?? 1, date: selected.date,
            state: WriterRequestNaming.state(request: selected.state.rawValue, calls: calls),
            title: request == nil
                ? copy.text("User input")
                : WriterRequestNaming.summary(
                    phase: phase, path: path, calls: calls, domain: metadata?["controlDomain"], language: copy),
            workspaceID: selected.decisionMetadata?.workspaceID)
        let finalization = turn.generationRounds?.first { $0.id == selected.id }.flatMap(Self.finalization)
        return .init(
            summary: summary, request: request, fallbackInput: selected.input.isEmpty ? turn.user : selected.input,
            toolSources: context.toolSources, finalization: finalization)
    }
    private static func finalization(_ round: ModelGenerationRound) -> WriterRequestFinalization? {
        guard let fields = try? JSONDecoder().decode([String: String].self, from: Data(round.resultsJSON.utf8)),
            fields["origin"] == "writer.runtime", fields["operation"] == "finalize",
            let state = fields["status"].flatMap(WriterRequestFinalization.State.init(rawValue:))
        else { return nil }
        return .init(state: state, result: fields["result"], error: fields["error"])
    }
    public func shareWorkspace(_ id: String) async throws -> String {
        guard !closed, let executions, let historyStore else { throw WriterFailure.unavailable }
        let item = try await workspace(id)
        let delegations = try await executions.requests(id, agent: "writer")
        var after: UInt64 = 0
        var messages: [WriterHistorySnapshot] = []
        var bytes = 0
        repeat {
            let page = try await historyStore.page(item.workspaceID, after: after)
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
            let workspace: WriterWorkspaceItem
            let delegations: [WriterRequestRecord]
            let messages: [WriterHistorySnapshot]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Export(workspace: item, delegations: delegations, messages: messages))
        guard data.count <= 32 * 1024 * 1024 else { throw WriterFailure.capacity }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Writer owns operation semantics; Storage only supplies invocation facts and UI only renders labels.
enum WriterRequestNaming {
    static func state(request: String, calls: [WriterToolPreview], pending: Bool = false) -> String {
        if ["failed", "cancelled", "interrupted"].contains(request) { return request }
        if calls.contains(where: { $0.state == "failed" }) { return "failed" }
        if calls.contains(where: { $0.state == "cancelled" }) { return "cancelled" }
        if pending || calls.contains(where: { $0.state == "received" }) { return "executing" }
        return request
    }
    static func phase(_ value: String) -> String {
        switch value {
        case "控制请求": "Control request"
        case "文件内容请求": "File content request"
        case "补充输入": "Follow-up input"
        case "输入": "Input"
        case "模型请求": "Model request"
        default: value
        }
    }

    static func summary(
        phase: String, path: String?, calls: [WriterToolPreview], domain: String? = nil,
        language: AppLanguage = .english
    ) -> String {
        func file(_ path: String?) -> String {
            guard let path, !path.isEmpty else { return language.text("File") }
            return path.count <= 40 ? path : (path as NSString).lastPathComponent
        }
        if Self.phase(phase) == "File content request" { return language.text("Write ") + file(path) }
        var titles: [String] = []
        for call in calls {
            let args = (try? JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))) ?? [:]
            let title: String
            switch call.name {
            case "workspace.search": title = language.text("Search the project library")
            case "workspace.create": title = language.text("Create and open workspace")
            case "workspace.enter": title = language.text("Open existing workspace")
            case "workspace.open": title = language.text("Open existing project")
            case "workspace.delete": title = language.text("Delete project")
            case "list": title = language.text("List workspace")
            case "read": title = language.text("Read ") + file(args["path"])
            case "search": title = language.text("Search files")
            case "edit":
                let instruction = args["instruction"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let brief =
                    !instruction.isEmpty && instruction.count <= 40
                    && !instruction.contains(where: { "\n\r<>{}".contains($0) || $0.asciiValue == 96 })
                title =
                    brief
                    ? instruction
                    : (args["reference"] == nil ? language.text("Write ") : language.text("Edit ")) + file(args["path"])
            case "replace": title = language.text("Edit ") + file(args["path"])
            case "move": title = language.text("Move ") + file(args["path"])
            case "remove", "removeTree": title = language.text("Delete ") + file(args["path"])
            case "render": title = language.text("Render and check the page")
            case "finish":
                title = domain == "library" ? language.text("Report library results") : language.text("Save project")
            case "ask": title = language.text("Wait for more information")
            case "rename": title = language.text("Rename project")
            case "savepoint": title = language.text("Save draft checkpoint")
            case "restore": title = language.text("Restore draft")
            case "diff": title = language.text("Check file changes")
            default: title = language.text("Process writing step")
            }
            if !titles.contains(title) {
                titles.append(title)
            }
        }
        guard let first = titles.first else { return language.text("Process writing step") }
        let title =
            titles.count == 1
            ? first
            : titles.prefix(2).joined(separator: (language == .simplifiedChinese ? "、" : ", "))
                + (titles.count > 2 ? language.format(" (%@ actions total)", String(titles.count)) : "")
        return title
    }
}
