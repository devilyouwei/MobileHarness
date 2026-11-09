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
    private var tasks: (any WriterExecutionRepository)?
    private var communications: (any AgentMessageRepository)?
    private var manager: AgentManager?
    private var output: OutputGateway?
    private var registered = false
    private var closed = false
    private var startBackground: WriterBackgroundExecution.Start?
    public private(set) var artifacts: (any WriterArtifactsControlling)?
    public func bindArtifacts(_ artifacts: (any WriterArtifactsControlling)?) { self.artifacts = artifacts }
    public private(set) var historyStore: WriterHistoryStore?
    public init() {}
    public func bindBackgroundExecution(_ start: @escaping WriterBackgroundExecution.Start) {
        startBackground = start
    }
    func configureHistory(
        messages: any WriterMessageRepository, tasks: any WriterExecutionRepository,
        communications: any AgentMessageRepository, logs: any ModelRequestLogRepository
    ) throws {
        guard historyStore == nil else { throw WriterFailure.unavailable }
        guard messages.storageScope == tasks.storageScope, messages.storageScope == communications.storageScope else {
            throw RecordStorageError.invalidRecord
        }
        self.tasks = tasks
        self.communications = communications
        historyStore = WriterHistoryStore(
            records: try WriterRecordStore(repository: messages, logs: logs))
    }
    func install(
        manager: AgentManager, output: OutputGateway, model: @escaping @Sendable () async throws -> ChatModel,
        streaming: any ArtifactStreaming
    ) throws {
        guard !closed, agent == nil, let historyStore, let tasks, let communications else {
            throw WriterFailure.unavailable
        }
        agent = try WriterAgent(
            model: model, streaming: streaming, history: historyStore, tasks: tasks, communications: communications,
            startBackground: startBackground)
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
        var workspace: WriterTaskItem?
        if !row.taskID.isEmpty { workspace = try await task(row.taskID) }
        var result: String?
        if let raw = row.result,
            let completion = try? JSONDecoder().decode(WriterTaskCompletion.self, from: Data(raw.utf8))
        {
            result = try AgentTaskContent.decode(completion.signal).text
        }
        let failure = row.failure.flatMap { raw in
            (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)))?["message"] ?? raw
        }
        var item = WriterDelegationItem(
            id: row.id, position: row.messageID, goal: row.goal, input: row.input, sourceAgent: row.sourceAgent,
            sourceContext: row.sourceContext, date: row.createdAt,
            state: ["closing", "cleanup_failed", "waiting_input", "paused"].contains(row.executionState)
                ? row.executionState : row.status, result: result,
            failure: failure, workspace: workspace)
        if let raw = row.waiting {
            item.waiting = try JSONDecoder().decode(AgentTaskContent.self, from: Data(raw.utf8)).text
        }
        return item
    }
    public func delegations(before: UInt64?) async throws -> WriterDelegationPage {
        guard !closed, let tasks else { throw WriterFailure.unavailable }
        let rows = try await tasks.delegations(before: before, limit: 21)
        var items: [WriterDelegationItem] = []
        for row in rows.prefix(20) { items.append(try await delegationItem(row)) }
        return .init(
            items: items, next: rows.count > 20 ? items.last?.position : nil, total: try await tasks.delegationCount())
    }
    public func delegation(_ id: String) async throws -> WriterDelegationItem {
        guard !closed, let tasks else { throw WriterFailure.unavailable }
        return try await delegationItem(tasks.request(id, agent: "writer"))
    }
    public func preflight(_ id: String, after: UInt64) async throws -> WriterRequestPage {
        guard !closed, let tasks, let historyStore else { throw WriterFailure.unavailable }
        let request = try await tasks.request(id, agent: "writer")
        let rows = try await historyStore.requestPreviews(
            "writer/preflight_" + String(request.messageID), after: after, limit: 21)
        return Self.messagePage(rows)
    }
    private static func messagePage(_ rows: [WriterMessagePreview]) -> WriterRequestPage {
        let items = rows.prefix(20).map { row in
            let label = WriterRequestNaming.summary(
                phase: row.metadata["phase"] ?? "补充输入", path: row.metadata["path"], calls: row.toolCalls,
                domain: row.metadata["controlDomain"])
            return WriterRequestItem(
                id: row.id, position: row.position, number: row.ordinal, delegateID: row.metadata["delegateID"] ?? "",
                phase: row.metadata["phase"] ?? "补充输入", path: row.metadata["path"],
                attempt: Int(row.metadata["attempt"] ?? "1") ?? 1, date: row.date,
                state: WriterRequestNaming.state(
                    request: row.state, calls: row.toolCalls, pending: row.metadata["toolsPending"] == "true"),
                title: label)
        }
        return .init(items: items, nextPosition: rows.count > 20 ? items.last?.position : nil)
    }
    public func tasks(before: String?) async throws -> WriterTaskPage {
        guard !closed, let tasks else { throw WriterFailure.unavailable }
        let cursor = try before.map { try BusinessRecordID.number($0, kind: .task) }
        var values: [WriterTaskItem] = []
        let rows = try await tasks.tasks(agent: "writer", before: cursor, limit: 21)
        for record in rows.prefix(20) {
            values.append(try await enrichedItem(record))
        }
        return .init(items: values, nextID: rows.count > 20 ? values.last?.id : nil)
    }
    private static func item(_ record: WriterWorkspaceRecord) -> WriterTaskItem {
        WriterTaskItem(
            id: record.id, dialogID: record.dialogID, goal: record.goal, workspaceID: record.workspaceID,
            updatedAt: record.updatedAt)
    }
    private func enrichedItem(_ record: WriterWorkspaceRecord) async throws -> WriterTaskItem {
        guard let historyStore else { throw WriterFailure.unavailable }
        var item = Self.item(record)
        item.isDeleted = record.status == "deleted"
        item.startedAt = try await historyStore.taskMetadata(record.dialogID).createdAt
        item.requestCount = try await historyStore.requestCount(record.dialogID)
        return item
    }
    public func task(_ id: String) async throws -> WriterTaskItem {
        guard !closed, let tasks else { throw WriterFailure.unavailable }
        let record = try await tasks.task(id, agent: "writer")
        return try await enrichedItem(record)
    }
    public func requests(taskID: String, after: UInt64) async throws -> WriterRequestPage {
        guard !closed, let tasks, let historyStore else { throw WriterFailure.unavailable }
        let record = try await tasks.task(taskID, agent: "writer")
        let rows = try await historyStore.requestPreviews(record.dialogID, after: after, limit: 21)
        return Self.messagePage(rows)
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
        let phase = metadata?["phase"] ?? selected.decisionMetadata?.mode ?? (request == nil ? "输入" : "模型请求")
        let path = metadata?["path"]
        let summary = WriterRequestItem(
            id: id, position: selected.historyOrder, number: context.ordinal,
            delegateID: selected.decisionMetadata?.delegateID ?? "", phase: phase, path: path,
            attempt: Int(metadata?["attempt"] ?? "1") ?? 1, date: selected.date,
            state: WriterRequestNaming.state(request: selected.state.rawValue, calls: calls),
            title: request == nil
                ? "用户输入"
                : WriterRequestNaming.summary(
                    phase: phase, path: path, calls: calls, domain: metadata?["controlDomain"]))
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
    public func shareTask(_ id: String) async throws -> String {
        guard !closed, let tasks, let historyStore else { throw WriterFailure.unavailable }
        let item = try await task(id)
        let delegations = try await tasks.requests(id, agent: "writer")
        var after: UInt64 = 0
        var messages: [WriterHistorySnapshot] = []
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
            let delegations: [WriterRequestRecord]
            let messages: [WriterHistorySnapshot]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Export(task: item, delegations: delegations, messages: messages))
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
    static func summary(phase: String, path: String?, calls: [WriterToolPreview], domain: String? = nil) -> String {
        func file(_ path: String?) -> String {
            guard let path, !path.isEmpty else { return "文件" }
            return path.count <= 40 ? path : (path as NSString).lastPathComponent
        }
        if phase == "文件内容请求" { return "编写 " + file(path) }
        var titles: [String] = []
        for call in calls {
            let args = (try? JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))) ?? [:]
            let title: String
            switch args["command"] {
            case "searchWorkspaces": title = "搜索作品库"
            case "create": title = "创建并进入工作区"
            case "enter": title = "进入已有工作区"
            case "open": title = "打开已有作品"
            case "delete": title = "删除已有作品"
            case "list": title = "查看工作区"
            case "read": title = "读取 " + file(args["path"])
            case "search": title = "查找文件内容"
            case "edit":
                let instruction = args["instruction"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let brief =
                    !instruction.isEmpty && instruction.count <= 40
                    && !instruction.contains(where: { "\n\r<>{}".contains($0) || $0.asciiValue == 96 })
                title = brief ? instruction : (args["reference"] == nil ? "编写 " : "修改 ") + file(args["path"])
            case "replace": title = "修改 " + file(args["path"])
            case "move": title = "移动 " + file(args["path"])
            case "remove", "removeTree": title = "删除 " + file(args["path"])
            case "render": title = "渲染并检查页面"
            case "finish":
                title = domain == "library" ? "汇报作品库结果" : domain?.hasPrefix("view:") == true ? "汇报呈现结果" : "保存作品"
            case "ask": title = "等待补充信息"
            case "rename": title = "修改作品名称"
            case "savepoint": title = "保存编辑检查点"
            case "restore": title = "恢复草稿"
            case "diff": title = "检查文件差异"
            default: title = "处理创作步骤"
            }
            if !titles.contains(title) {
                titles.append(title)
            }
        }
        guard let first = titles.first else { return "处理创作步骤" }
        let title =
            titles.count == 1
            ? first
            : titles.prefix(2).joined(separator: "、")
                + (titles.count > 2 ? "等\(titles.count)项操作" : "")
        return title
    }
}
