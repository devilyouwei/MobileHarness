import AgentCore
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

/// Read model for the Writer records UI: delegations, workspaces, request history and export.
@MainActor public final class WriterRecords: WriterRecordsControlling {
    private let executions: any WriterExecutionRepository
    private let historyStore: WriterHistoryStore
    private var closed = false
    var language: @Sendable () -> String = { "en" }
    private var copy: AppLanguage { AppLanguage(preferredLanguage: language()) }

    init(executions: any WriterExecutionRepository, historyStore: WriterHistoryStore) {
        self.executions = executions
        self.historyStore = historyStore
    }

    func close() { closed = true }

    public func clearRequestLogs(requestID: String?) async throws {
        guard !closed else { throw WriterFailure.unavailable }
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
        guard !closed else { throw WriterFailure.unavailable }
        let rows = try await executions.delegations(before: before, limit: 21)
        var items: [WriterDelegationItem] = []
        for row in rows.prefix(20) { items.append(try await delegationItem(row)) }
        return .init(
            items: items, next: rows.count > 20 ? items.last?.position : nil,
            total: try await executions.delegationCount())
    }
    public func delegation(_ id: String) async throws -> WriterDelegationItem {
        guard !closed else { throw WriterFailure.unavailable }
        return try await delegationItem(executions.request(id, agent: "writer"))
    }
    public func preflight(_ id: String, after: UInt64) async throws -> WriterRequestPage {
        guard !closed else { throw WriterFailure.unavailable }
        let request = try await executions.request(id, agent: "writer")
        let rows = try await historyStore.preflightPreviews(
            requestMessageID: request.messageID, after: after, limit: 21)
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
                phase: copy.text(row.metadata["phase"] ?? "Follow-up input"),
                path: row.metadata["path"],
                attempt: Int(row.metadata["attempt"] ?? "1") ?? 1, date: row.date,
                state: WriterRequestNaming.state(
                    request: row.state, calls: row.toolCalls, pending: row.metadata["toolsPending"] == "true"),
                title: label)
        }
        return .init(items: items, nextPosition: rows.count > 20 ? items.last?.position : nil)
    }
    public func workspaces(before: String?) async throws -> WriterWorkspacePage {
        guard !closed else { throw WriterFailure.unavailable }
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
        var item = Self.item(record)
        item.isDeleted = record.status == "deleted"
        item.startedAt = try await historyStore.ownerMetadata(record.workspaceID).createdAt
        item.requestCount = try await historyStore.requestCount(record.workspaceID)
        return item
    }
    public func workspace(_ id: String) async throws -> WriterWorkspaceItem {
        guard !closed else { throw WriterFailure.unavailable }
        let record = try await executions.workspace(id, agent: "writer")
        return try await enrichedItem(record)
    }
    public func requests(workspaceID: String, after: UInt64) async throws -> WriterRequestPage {
        guard !closed else { throw WriterFailure.unavailable }
        let record = try await executions.workspace(workspaceID, agent: "writer")
        let rows = try await historyStore.requestPreviews(record.workspaceID, after: after, limit: 21)
        return messagePage(rows)
    }
    public func requests(workspaceID: String, before: UInt64?) async throws -> WriterRequestPage {
        guard !closed else { throw WriterFailure.unavailable }
        guard WorkspaceID(rawValue: workspaceID) != nil else { throw RecordStorageError.invalidID }
        let rows = try await historyStore.requestPreviews(workspaceID, before: before, limit: 21)
        return messagePage(rows)
    }
    public func requestDetail(_ id: String) async throws -> WriterRequestDetails {
        guard !closed else { throw WriterFailure.unavailable }
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
            delegateID: selected.decisionMetadata?.delegateID ?? "", phase: copy.text(phase),
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
        guard !closed else { throw WriterFailure.unavailable }
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
