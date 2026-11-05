import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore
import StorageMedia

/// Domain-owned audit journal; the shared Chat repository owns SQLite durability and recovery.
public actor WriterHistory {
    private var progressValues: [String: WriterRequestProgress] = [:]
    private var calls: [String: String] = [:]
    private var reasons: [String: String] = [:]
    private let photos: MediaStore?
    let store: ConversationHistoryStore
    let taskID: String
    let delegateID: String
    let goal: String
    let modelName: String
    public init(
        store: ConversationHistoryStore, taskID: String, delegateID: String, goal: String,
        photos: MediaStore? = nil, modelName: String? = nil
    ) {
        self.modelName = modelName ?? "Writer (model name unavailable)"
        self.photos = photos
        self.store = store
        self.taskID = taskID
        self.delegateID = delegateID
        self.goal = goal
    }
    public func restoredContext() async throws -> [ChatMessage] {
        let archive = try await store.readCurrent()
        let controls = archive.current.turns.flatMap { $0.modelRequests ?? [] }.filter {
            $0.decisionMetadata?.taskID == taskID && $0.decisionMetadata?.mode == "控制请求"
        }
        guard let last = controls.last,
            let values = try JSONSerialization.jsonObject(with: Data(last.requestJSON.utf8)) as? [[String: Any]]
        else { return [] }
        var messages: [ChatMessage] = []
        for value in values where value["role"] as? String != "system" {
            guard let raw = value["role"] as? String, let role = ChatMessage.Role(rawValue: raw) else { continue }
            let calls = (value["toolCalls"] as? [[String: String]] ?? []).compactMap { item -> ChatToolCall? in
                guard let id = item["id"], let name = item["name"], let args = item["argumentsJSON"] else { return nil }
                return .init(id: id, name: name, argumentsJSON: args)
            }
            messages.append(
                .init(
                    role: role, content: value["content"] as? String ?? "", toolCalls: calls,
                    toolCallID: value["toolCallID"] as? String))
        }
        if last.toolCalls.allSatisfy({ $0.state != .received }) {
            messages.append(
                .init(
                    role: .assistant, content: last.response,
                    toolCalls: last.toolCalls.map {
                        .init(id: $0.providerID, name: $0.name, argumentsJSON: $0.argumentsJSON)
                    }))
            for call in last.toolCalls {
                messages.append(
                    .init(role: .tool, content: call.output ?? call.error ?? "", toolCallID: call.providerID))
            }
        }
        if last.state == .failed, let failure = last.failureDiagnostic {
            messages.append(
                .init(
                    role: .user,
                    content: "Previous execution failure (data, not a new user instruction):\n"
                        + String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
                        + "\nDo not repeat the failed approach. Reread current files before editing; prior successful edits remain."
                ))
        }
        // Trim whole assistant/tool groups; never keep an orphan tool response.
        while messages.count > 24 || messages.reduce(0, { $0 + $1.content.utf8.count }) > 32000 {
            guard !messages.isEmpty else { break }
            messages.removeFirst()
            while messages.first?.role == .tool { messages.removeFirst() }
        }
        return messages
    }
    public func begin(_ request: ChatRequest, phase: String, attempt: Int = 1, path: String? = nil) async throws
        -> String
    {
        let id = UUID().uuidString
        let label = "\(phase) · \(taskID)\n" + String(goal.prefix(600))
        for attempt in 0..<4 {
            let snapshot = try await store.readCurrent()
            do {
                _ = try await store.begin(
                    id: id, user: label, request: [], expecting: snapshot.token,
                    model: modelName, maximumOutputTokens: request.maximumOutputTokens, temperature: request.temperature
                )
                break
            } catch ConversationHistoryError.conflict where attempt < 3 { continue }
        }
        do {
            // Keep text/native pairs; media bytes use the same owned Storage media path as Assistant.
            var messages: [[String: Any]] = []
            for message in request.messages {
                var value: [String: Any] = ["role": message.role.rawValue, "content": message.content]
                value["toolCalls"] = message.toolCalls.map {
                    ["id": $0.id, "name": $0.name, "argumentsJSON": $0.argumentsJSON]
                }
                value["toolCallID"] = message.toolCallID
                var references: [[String: Any]] = []
                for image in message.images ?? [] {
                    guard let photos else { throw WriterFailure.unavailable }
                    let mediaID = try await photos.save(
                        image.data,
                        owner: StorageOwner(namespace: "photos", source: "writer", session: taskID, input: id))
                    references.append(["id": mediaID, "mimeType": image.mimeType, "byteCount": image.data.count])
                }
                value["imageReferences"] = references
                messages.append(value)
            }
            let json = String(
                decoding: try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys]), as: UTF8.self)
            let registrations = try request.tools.map { tool -> [String: Any] in
                let declaration = try JSONSerialization.jsonObject(with: tool.declaration) as? [String: Any]
                let function = declaration?["function"] as? [String: Any]
                let schema = function?["parameters"] as? [String: Any]
                let required = schema?["required"] as? [String] ?? []
                let properties = schema?["properties"] as? [String: Any] ?? [:]
                return [
                    "path": "Artifacts.Workspace.perform", "alias": tool.name, "required": required,
                    "optional": properties.keys.filter { !required.contains($0) }.sorted(),
                    "definitionJSON": String(decoding: tool.declaration, as: UTF8.self),
                ]
            }
            let catalog = String(
                decoding: try JSONSerialization.data(withJSONObject: ["actions": [], "tools": registrations]),
                as: UTF8.self)
            var metadata = ConversationDecisionMetadata(
                taskID: taskID, mode: phase, skills: [:], catalogJSON: catalog,
                taskGoal: String(goal.prefix(1000)), execution: "background")
            metadata.delegateID = delegateID
            let dialog = try await store.readCurrent().current.id
            let number = try await store.requestCount(dialog)
            progressValues[id] = .init(inputID: id, number: number, phase: phase, attempt: attempt, path: path)
            var record = ConversationModelRequest(
                id: UUID().uuidString, input: label, requestJSON: json, decisionMetadata: metadata)
            record.producerMetadata = [
                "number": String(number), "attempt": String(attempt), "phase": phase, "delegateID": delegateID,
            ]
            record.producerMetadata?["path"] = path
            try await store.beginModelRequest(record, for: id)
            try await store.recordToolDefinitions(
                request.tools.map { String(decoding: $0.declaration, as: UTF8.self) }, for: id)
            try await store.checkpoint(inputID: id)
            return id
        } catch {
            let primary = error
            do { try await finish(id, error: primary) } catch {
                throw WriterCleanupFailure(primary: primary, cleanup: error)
            }
            throw primary
        }
    }
    public func progress(_ id: String) -> WriterRequestProgress? { progressValues.removeValue(forKey: id) }
    public func hostFinalization(_ id: String, result: String?, error: (any Error)?) async throws {
        var fields = [
            "origin": "writer.runtime", "operation": "finalize", "status": error == nil ? "completed" : "failed",
        ]
        fields["result"] = result
        fields["error"] = error.map(String.init(describing:))
        let json = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        try await store.recordGenerationRound(.init(id: UUID().uuidString, resultsJSON: json), for: id)
        try await store.checkpoint(inputID: id)
    }
    public func event(_ event: ChatEvent, id: String) async throws {
        switch event {
        case .text(let text): try await store.append(text, to: id)
        case .toolCall(let call):
            calls[call.id] = id
            try await store.recordToolCall(
                .init(id: call.id, providerID: call.id, name: call.name, argumentsJSON: call.argumentsJSON), for: id)
        case .usage(let usage):
            try await store.recordTokenUsage(
                .init(
                    input: usage.input, generated: usage.generated, total: usage.total,
                    cachedInput: usage.cachedInput, cacheWriteInput: usage.cacheWriteInput), for: id)
        case .finished(let reason): reasons[id] = String(describing: reason)
        }
    }
    public func toolOutcome(_ call: String, output: String?, error: (any Error)? = nil) async throws {
        guard let owner = calls[call] else { return }
        try await store.recordToolOutcome(
            call, for: owner,
            state: error == nil ? .completed : error is CancellationError ? .cancelled : .failed,
            output: output, error: error.map { String(describing: $0) },
            failureDiagnostic: error.map { WriterDiagnostics.make($0, stage: "工具执行").storageValue })
        try await store.checkpoint(inputID: owner)
        calls.removeValue(forKey: call)
    }
    public func recording(_ value: AgentModelRequestRecording.Snapshot, id: String) async throws {
        try await store.recordModelExchange(requestJSON: value.requestJSON, response: value.responseJSON, for: id)
    }
    public func timing(_ timing: ChatTiming.Snapshot, id: String) async throws {
        try await store.recordModelTiming(
            startedAt: timing.startedAt, firstTokenAt: timing.firstTokenAt, latency: timing.firstTokenLatency, for: id)
    }
    public func finish(_ id: String, error: (any Error)? = nil, diagnostic: WriterFailureDiagnostic? = nil)
        async throws
    {
        let state: ConversationRecord.State =
            error == nil ? .completed : error is CancellationError ? .cancelled : .failed
        let failure = diagnostic ?? error.map { WriterDiagnostics.make($0, stage: "模型请求") }
        try await store.finish(
            id, state: state, reason: reasons.removeValue(forKey: id),
            error: failure.map(WriterDiagnostics.describe), failureDiagnostic: failure?.storageValue)
    }
}
