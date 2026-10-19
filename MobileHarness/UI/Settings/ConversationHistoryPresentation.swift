import Foundation

public struct HistoryTaskReference: Equatable, Sendable, Identifiable {
    public let id: String
    public let isHistoryOwner: Bool
    public let wasActiveAtRequest: Bool
}

public struct HistoryFunctionRegistration: Decodable, Sendable {
    public let path: String
    public let alias: String
    public let channel: String?
    public let required: [String]
    public let optional: [String]
    public let definitionJSON: String?
}

public struct HistoryFunctionCatalog: Decodable, Sendable {
    public let actions: [HistoryFunctionRegistration]
    public let tools: [HistoryFunctionRegistration]
}

public enum ConversationHistoryPresentation {
    public static func functionCatalog(_ json: String) throws -> HistoryFunctionCatalog {
        try JSONDecoder().decode(HistoryFunctionCatalog.self, from: Data(json.utf8))
    }

    @concurrent public static func functionCatalogOffMain(_ json: String) async throws -> HistoryFunctionCatalog {
        try Task.checkCancellation()
        let result = try functionCatalog(json)
        try Task.checkCancellation()
        return result
    }
    @concurrent public static func timelineOffMain(_ conversation: HistoryConversation) async throws
        -> [HistoryTimelineItem]
    {
        try Task.checkCancellation()
        let result = timeline(conversation)
        try Task.checkCancellation()
        return result
    }

    public static func taskReferences(for turn: HistoryTurn) -> [HistoryTaskReference] {
        var references: [HistoryTaskReference] = []
        if let id = turn.historyTaskID {
            references.append(
                HistoryTaskReference(
                    id: id, isHistoryOwner: true, wasActiveAtRequest: id == turn.decisionMetadata?.taskID))
        }
        if let id = turn.decisionMetadata?.taskID, id != turn.historyTaskID {
            references.append(HistoryTaskReference(id: id, isHistoryOwner: false, wasActiveAtRequest: true))
        }
        return references
    }

    public static func title(_ conversation: HistoryConversation) -> String {
        if conversation.archivedAt != nil { return conversation.summaryTitle ?? "待生成标题" }
        return conversation.latestUser ?? conversation.turns.last?.user ?? "新对话"
    }
    /// Export the page's original Codable value; preserve raw request strings and evidence.
    public static func jsonData<Value: Encodable>(_ value: Value, maximumBytes: Int = 32 * 1024 * 1024) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard maximumBytes > 0, data.count <= maximumBytes else { throw HistoryJSONExportError.capacityExceeded }
        return data
    }
    /// Presentation peers preserve the original input's nested execution ownership on disk.
    public static func turns(_ conversation: HistoryConversation) -> [HistoryTurn] {
        conversation.turns.flatMap { turn -> [HistoryTurn] in
            return (turn.modelRequests ?? []).enumerated().map { index, request in
                project(
                    turn, messageID: request.messageID, id: request.id, date: request.date, input: request.input,
                    requestJSON: request.requestJSON, firstTokenAt: request.firstTokenAt,
                    calls: request.toolCalls, usage: request.tokenUsage, response: request.response,
                    state: request.state, reason: request.finishReason,
                    error: request.error ?? (index == (turn.modelRequests?.count ?? 0) - 1 ? turn.error : nil),
                    react: request.isObservation ?? (index > 0), modelRequestStartedAt: request.modelRequestStartedAt,
                    firstTokenLatency: request.firstTokenLatency, decisionMetadata: request.decisionMetadata,
                    historyTaskID: request.historyTaskID, historyOrder: request.historyOrder)
            }
        }.sorted { ($0.historyOrder ?? 0) < ($1.historyOrder ?? 0) }
    }

    private static func project(
        _ parent: HistoryTurn, messageID: String? = nil, id: String, date: Date, input: String, requestJSON: String?,
        firstTokenAt: Date?,
        calls: [HistoryToolCall]?, usage: HistoryTokenUsage?, response: String, state: HistoryTurn.State,
        reason: String?, error: String?, react: Bool,
        modelRequestStartedAt: Date? = nil, firstTokenLatency: Double? = nil,
        decisionMetadata: HistoryDecisionMetadata? = nil, historyTaskID: String? = nil, historyOrder: UInt64 = 0
    ) -> HistoryTurn {
        HistoryTurn(
            messageID: messageID, historyOrder: historyOrder, id: id, date: date, user: input,
            request: requestJSON.flatMap { try? JSONDecoder().decode([HistoryMessage].self, from: Data($0.utf8)) }
                ?? [],
            model: parent.model, maximumOutputTokens: parent.maximumOutputTokens, temperature: parent.temperature,
            modelRequests: nil, firstTokenAt: firstTokenAt, requestJSON: requestJSON, ownerInputID: parent.id,
            isReACT: react,
            toolDefinitions: parent.toolDefinitions, toolCalls: calls, tokenUsage: usage,
            response: response, state: state, finishReason: reason, error: error,
            executionError: parent.executionError,
            historyTaskID: historyTaskID, decisionMetadata: decisionMetadata,
            modelRequestStartedAt: modelRequestStartedAt,
            firstTokenLatency: firstTokenLatency)
    }

    public static func timeline(_ conversation: HistoryConversation) -> [HistoryTimelineItem] {
        let requests = turns(conversation)
        let grouped = requests.reduce(into: [String: [HistoryTurn]]()) { groups, turn in
            if let id = turn.historyTaskID { groups[id, default: []].append(turn) }
        }
        var replacements: [String: HistoryTaskCompression] = [:]
        for compression in conversation.taskCompressions {
            let owned = grouped[compression.taskID] ?? []
            let references = Set(compression.sources)
            if !owned.isEmpty, compression.status != .generating,
                owned.allSatisfy({
                    $0.state != .generating
                        && references.contains(.init(inputID: $0.ownerInputID ?? $0.id, requestID: $0.id))
                })
            {
                replacements[compression.taskID] = compression
            }
        }
        var emitted: Set<String> = []
        return requests.compactMap { turn in
            if let taskID = turn.historyTaskID, let compression = replacements[taskID] {
                return emitted.insert(taskID).inserted
                    ? .task(compression, sources: grouped[taskID] ?? []) : nil
            }
            return .request(turn)
        }
    }

}

extension HistoryTurn {
    public var effectiveToolDefinitions: [String] {
        if let metadata = decisionMetadata,
            let root = try? JSONSerialization.jsonObject(with: Data(metadata.catalogJSON.utf8)) as? [String: Any],
            let tools = root["tools"] as? [[String: Any]]
        {
            return tools.compactMap { $0["definitionJSON"] as? String }.filter { !$0.isEmpty }
        }
        return toolDefinitions ?? []
    }

    public var dateReport: String { date.formatted() }
    public var stateReport: String { state.rawValue }

    public var outputSummary: String {
        if !raw.isEmpty { return raw }
        guard let calls = toolCalls, !calls.isEmpty else {
            return ""
        }
        return "Tool Call：" + calls.map(\.name).joined(separator: "、")
    }
    public var firstTokenReport: String {
        guard modelRequestStartedAt != nil, firstTokenAt != nil, let delay = firstTokenLatency else {
            return "首 token 耗时："
        }
        return "首 token 耗时：\(String(format: "%.3f", delay)) 秒"
    }
    public var tokenReport: String {
        guard let usage = tokenUsage else { return "Token 用量：" }
        var report = "输入：\(usage.input) tokens · 生成：\(usage.generated) tokens · 总计：\(usage.total) tokens"
        if let cached = usage.cachedInput { report += " · 缓存读取：\(cached) tokens" }
        if let written = usage.cacheWriteInput { report += " · 缓存写入：\(written) tokens" }
        return report
    }

}

extension HistoryMessage {
    public var attachedImages: [HistoryImageReference] {
        guard role == .user else { return [] }
        return Array((imageReferences ?? []).filter(\.isValid).prefix(4))
    }
    public var displayContent: String { content }

}

extension HistoryToolCall {
    public var responseReport: String {
        var sections = ["Tool Call · \(name) · \(state.rawValue)", "Arguments:\n\(argumentsJSON)"]
        if let output { sections.append("Result:\n\(output)") }
        if let error { sections.append("Error:\n\(error)") }
        return sections.joined(separator: "\n\n")
    }
}

extension HistoryTurn {
    public var displayInput: String { user }
    public var attachedImages: [HistoryImageReference] {
        var seen: Set<String> = []
        return Array(request.flatMap(\.attachedImages).filter { seen.insert($0.id).inserted }.prefix(4))
    }
}

public enum HistoryJSONExportError: Error { case capacityExceeded }
