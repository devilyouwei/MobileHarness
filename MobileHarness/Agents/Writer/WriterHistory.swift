import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore

/// Writer-owned audit journal backed by its private message store and the shared log port.
public actor WriterHistory {
    private var progressValues: [String: WriterRequestProgress] = [:]
    private var calls: [String: String] = [:]
    private var reasons: [String: String] = [:]
    let store: WriterHistoryStore
    let delegateID: String
    let goal: String
    let modelName: String
    let toolPaths: [String: String]
    public init(
        store: WriterHistoryStore, delegateID: String, goal: String,
        modelName: String? = nil, toolPaths: [String: String] = [:]
    ) {
        self.modelName = modelName ?? "Writer (model name unavailable)"
        self.store = store
        self.delegateID = delegateID
        self.goal = goal
        self.toolPaths = toolPaths
    }
    public func restoredContext(domain: String? = nil, availableTools: Set<String>? = nil) async throws -> [ChatMessage]
    {
        let archive = try await store.readCurrent()
        let controls = archive.current.turns.flatMap { $0.modelRequests ?? [] }.filter {
            $0.decisionMetadata?.delegateID == delegateID && $0.decisionMetadata?.mode == "控制请求"
                && (domain == nil || $0.producerMetadata?["controlDomain"] == domain)
        }
        guard let last = controls.last else { return [] }
        var messages: [ChatMessage] = []
        var previousInput: String?
        for record in controls {
            if record.input != previousInput {
                messages.append(.init(role: .user, content: record.input))
                previousInput = record.input
            }
            if let availableTools, record.toolCalls.contains(where: { !availableTools.contains($0.name) }) {
                let evidence = record.toolCalls.filter { $0.state != .received }.map {
                    $0.name + " " + $0.argumentsJSON + "\n" + ($0.output ?? $0.error ?? "")
                }
                let body = ([record.response] + evidence).filter { !$0.isEmpty }.joined(separator: "\n")
                if !body.isEmpty {
                    messages.append(.init(role: .user, content: "Earlier tool evidence (data):\n" + body))
                }
                continue
            }
            // Restore only complete call/result groups from durable business evidence.
            if record.toolCalls.allSatisfy({ $0.state != .received }) {
                if !record.response.isEmpty || !record.toolCalls.isEmpty {
                    messages.append(
                        .init(
                            role: .assistant, content: record.response,
                            toolCalls: record.toolCalls.map {
                                .init(id: $0.providerID, name: $0.name, argumentsJSON: $0.argumentsJSON)
                            }))
                }
                for call in record.toolCalls {
                    messages.append(
                        .init(role: .tool, content: call.output ?? call.error ?? "", toolCallID: call.providerID))
                }
            } else if !record.response.isEmpty {
                messages.append(.init(role: .assistant, content: record.response))
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
        while messages.count > 24
            || messages.reduce(
                0,
                { total, message in
                    total + message.content.utf8.count
                        + message.toolCalls.reduce(0) {
                            $0 + $1.argumentsJSON.utf8.count + $1.name.utf8.count + $1.id.utf8.count
                        }
                }) > 32000
        {
            guard !messages.isEmpty else { break }
            messages.removeFirst()
            while messages.first?.role == .tool { messages.removeFirst() }
        }
        return messages
    }
    public func begin(
        _ request: ChatRequest, phase: String, attempt: Int = 1, path: String? = nil, domain: String? = nil
    ) async throws
        -> String
    {
        let ownerID = try await store.readCurrent().current.id
        let workspaceID = domain.flatMap { value in
            value.hasPrefix("workspace:") ? WorkspaceID(rawValue: String(value.dropFirst("workspace:".count))) : nil
        }?.rawValue
        let id = UUID().uuidString
        let label = "\(phase) · \(workspaceID ?? ownerID)\n" + String(goal.prefix(600))
        for attempt in 0..<4 {
            let snapshot = try await store.readCurrent()
            do {
                _ = try await store.begin(
                    id: id, user: label, request: [], expecting: snapshot.token,
                    model: modelName, maximumOutputTokens: request.maximumOutputTokens, temperature: request.temperature
                )
                break
            } catch WriterHistoryError.conflict where attempt < 3 { continue }
        }
        do {
            // Keep lightweight admission references; the shared recorder owns complete request bytes.
            var messages: [[String: Any]] = []
            for message in request.messages {
                var value: [String: Any] = ["role": message.role.rawValue, "content": message.content]
                value["toolCalls"] = message.toolCalls.map {
                    ["id": $0.id, "name": $0.name, "argumentsJSON": $0.argumentsJSON]
                }
                value["toolCallID"] = message.toolCallID
                var references: [[String: Any]] = []
                for image in message.images ?? [] {
                    references.append(["id": image.id, "mimeType": image.mimeType, "byteCount": image.data.count])
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
                    "path": toolPaths[tool.name] ?? "Agent.Writer." + tool.name, "alias": tool.name,
                    "required": required,
                    "optional": properties.keys.filter { !required.contains($0) }.sorted(),
                    "definitionJSON": String(decoding: tool.declaration, as: UTF8.self),
                ]
            }
            let catalog = String(
                decoding: try JSONSerialization.data(withJSONObject: ["actions": [], "tools": registrations]),
                as: UTF8.self)
            var metadata = WriterDecisionMetadata(
                workspaceID: workspaceID, mode: phase, skills: [:], catalogJSON: catalog,
                delegationGoal: String(goal.prefix(1000)), execution: "background")
            metadata.delegateID = delegateID
            let historyID = try await store.readCurrent().current.id
            let number = try await store.requestCount(historyID)
            progressValues[id] = .init(inputID: id, number: number, phase: phase, attempt: attempt, path: path)
            var record = WriterModelRequest(
                id: UUID().uuidString, input: label, requestJSON: json, decisionMetadata: metadata)
            let inputStart = request.messages.lastIndex(where: { $0.role == .assistant }).map { $0 + 1 } ?? 0
            record.inputMessages = request.messages.dropFirst(inputStart).compactMap { message in
                guard let role = WriterInputMessage.Role(rawValue: message.role.rawValue) else { return nil }
                let name = request.messages.reversed().flatMap(\.toolCalls)
                    .first { $0.id == message.toolCallID }?.name
                return WriterInputMessage(
                    role: role, content: message.content,
                    toolCallID: message.toolCallID, toolName: name)
            }
            record.producerMetadata = [
                "number": String(number), "attempt": String(attempt), "phase": phase, "delegateID": delegateID,
            ]
            record.producerMetadata?["path"] = path
            record.producerMetadata?["controlDomain"] = domain
            try await store.beginModelRequest(record, for: id)
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
        if let update = value.transport {
            try await store.recordModelTransport(update, for: id)
            return
        }
        try await store.recordModelExchange(
            requestJSON: value.requestJSON, response: value.responseJSON, for: id, initial: value.initial)
    }
    public func timing(_ timing: ChatTiming.Snapshot, id: String) async throws {
        try await store.recordModelTiming(
            startedAt: timing.startedAt, firstTokenAt: timing.firstTokenAt, latency: timing.firstTokenLatency, for: id)
    }
    public func finish(_ id: String, error: (any Error)? = nil, diagnostic: WriterFailureDiagnostic? = nil)
        async throws
    {
        let state: WriterRecord.State =
            error == nil ? .completed : error is CancellationError ? .cancelled : .failed
        let failure = diagnostic ?? error.map { WriterDiagnostics.make($0, stage: "模型请求") }
        try await store.finish(
            id, state: state, reason: reasons.removeValue(forKey: id),
            error: failure.map(WriterDiagnostics.describe), failureDiagnostic: failure?.storageValue)
    }
}
