import Foundation

public enum ConversationHistoryPresentation {
    public static func title(_ conversation: HistoryConversation) -> String {
        if conversation.archivedAt != nil { return conversation.summaryTitle ?? "待生成标题" }
        return conversation.turns.last?.user ?? "新对话"
    }
    /// Presentation peers preserve the original input's nested execution ownership on disk.
    public static func turns(_ conversation: HistoryConversation, inputIDs: Set<UUID>? = nil) -> [HistoryTurn] {
        conversation.turns.flatMap { turn -> [HistoryTurn] in
            guard inputIDs == nil || inputIDs!.contains(turn.id) else { return [] }
            return (turn.modelRequests ?? []).enumerated().map { index, request in
                project(
                    turn, id: request.id, date: request.date, input: request.input,
                    requestJSON: request.requestJSON, firstTokenAt: request.firstTokenAt,
                    calls: request.toolCalls, usage: request.tokenUsage, fragments: request.fragments,
                    state: request.state, reason: request.finishReason,
                    error: request.error ?? (index == (turn.modelRequests?.count ?? 0) - 1 ? turn.error : nil),
                    react: index > 0, modelRequestStartedAt: request.modelRequestStartedAt,
                    firstTokenLatency: request.firstTokenLatency, decisionMetadata: request.decisionMetadata)
            }
        }
    }

    private static func project(
        _ parent: HistoryTurn, id: UUID, date: Date, input: String, requestJSON: String?, firstTokenAt: Date?,
        calls: [HistoryToolCall]?, usage: HistoryTokenUsage?, fragments: [String], state: HistoryTurn.State,
        reason: String?, error: String?, react: Bool,
        modelRequestStartedAt: Date? = nil, firstTokenLatency: Double? = nil,
        decisionMetadata: HistoryDecisionMetadata? = nil
    ) -> HistoryTurn {
        HistoryTurn(
            id: id, date: date, user: input,
            request: requestJSON.flatMap { try? JSONDecoder().decode([HistoryMessage].self, from: Data($0.utf8)) }
                ?? [],
            model: parent.model, maximumOutputTokens: parent.maximumOutputTokens, temperature: parent.temperature,
            modelRequests: nil, firstTokenAt: firstTokenAt, requestJSON: requestJSON, ownerInputID: parent.id,
            isReACT: react,
            toolDefinitions: parent.toolDefinitions, toolCalls: calls, tokenUsage: usage,
            fragments: fragments, state: state, finishReason: reason, error: error,
            executionError: parent.executionError,
            decisionMetadata: decisionMetadata, modelRequestStartedAt: modelRequestStartedAt,
            firstTokenLatency: firstTokenLatency)
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
        return "输入：\(usage.input) tokens · 生成：\(usage.generated) tokens · 总计：\(usage.total) tokens"
    }
    public var toolReport: String {
        guard let calls = toolCalls, !calls.isEmpty else { return "" }
        return calls.map { call in
            """
            Name: \(call.name)
            Provider ID: \(call.providerID); runtime ID: \(call.id)
            State: \(call.state.rawValue)
            Input: \(call.argumentsJSON)
            Output: \(call.output ?? "")
            Error: \(call.error ?? "")
            """
        }.joined(separator: "\n\n")
    }
    public func diagnosticReport(interpretation: String = "") -> String {
        let messages = requestJSON ?? request.map { "[\($0.role.rawValue)]\n\($0.content)" }.joined(separator: "\n\n")
        return """
            Model round: \(id.uuidString)
            Owning input: \(ownerInputID ?? id)
            ReACT: \(isReACT == true)
            Model: \(model)
            Date: \(date.ISO8601Format())
            Model request started: \(modelRequestStartedAt.map { $0.ISO8601Format() } ?? "")
            First token: \(firstTokenAt.map { $0.ISO8601Format() } ?? "")
            \(firstTokenReport)
            State: \(stateReport); finish: \(finishReason ?? "")
            Temperature: \(temperature)
            Tokens: \(tokenReport)
            Generation error: \(error ?? "")
            Execution error: \(executionError ?? "")

            CURRENT INPUT
            \(user)

            ACTUAL REQUEST
            \(messages)

            ACTUAL TOOL DEFINITIONS
            \((toolDefinitions ?? []).joined(separator: "\n\n"))

            RAW MODEL TEXT
            \(raw)

            TOOL CALL INPUT / OUTPUT
            \(toolReport)

            RECEIVED FRAGMENTS (escaped)
            \(fragments.enumerated().map { "\($0.offset + 1). \(String(reflecting: $0.element))" }.joined(separator: "\n"))

            CURRENT PARSER PREVIEW (not execution evidence)
            \(interpretation)
            """
    }
}

extension HistoryMessage {
    public var attachedImages: [HistoryImageReference] {
        guard role == .user else { return [] }
        return Array((imageReferences ?? []).filter(\.isValid).prefix(4))
    }
    public var displayContent: String { content }

}

extension HistoryTurn {
    public var displayInput: String { user }
    public var attachedImages: [HistoryImageReference] {
        var seen: Set<UUID> = []
        return Array(request.flatMap(\.attachedImages).filter { seen.insert($0.id).inserted }.prefix(4))
    }
}
