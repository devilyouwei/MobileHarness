import Foundation

public enum ConversationHistoryPresentation {
    public static func title(_ conversation: HistoryConversation) -> String {
        if conversation.archivedAt != nil { return conversation.summaryTitle ?? "待生成标题" }
        return conversation.turns.last?.user ?? "新对话"
    }
    /// Presentation peers preserve the original input's nested execution ownership on disk.
    public static func turns(_ conversation: HistoryConversation) -> [HistoryTurn] {
        conversation.turns.flatMap { turn -> [HistoryTurn] in
            if let requests = turn.modelRequests, !requests.isEmpty {
                return requests.enumerated().map { index, request in
                    project(
                        turn, id: request.id, date: request.date, input: request.input,
                        requestJSON: request.requestJSON, firstTokenAt: request.firstTokenAt,
                        calls: request.toolCalls, usage: request.tokenUsage, fragments: request.fragments,
                        state: request.state, reason: request.finishReason,
                        error: request.error ?? (index == requests.count - 1 ? turn.error : nil),
                        react: index > 0)
                }
            }
            guard let continuations = turn.continuationRequests, !continuations.isEmpty else { return [turn] }
            let original = project(
                turn, id: turn.id, date: turn.date, input: turn.user, requestJSON: nil, firstTokenAt: nil,
                calls: turn.toolCalls, usage: turn.tokenUsage, fragments: turn.fragments, state: turn.state,
                reason: turn.finishReason, error: turn.error, react: false)
            var previous = turn.request
            let legacy = continuations.enumerated().map { index, json in
                let messages = try? JSONDecoder().decode([HistoryMessage].self, from: Data(json.utf8))
                let observations = messages.map { Array($0.dropFirst(previous.count)).filter { $0.role != .assistant } }
                let input = observations?.map { "[\($0.role.rawValue)]\n\($0.content)" }.joined(separator: "\n\n")
                if let messages { previous = messages }
                var identity = turn.id.uuid
                withUnsafeMutableBytes(of: &identity) { $0[15] ^= UInt8(index + 1) }
                return project(
                    turn, id: UUID(uuid: identity), date: turn.date,
                    input: input.flatMap { $0.isEmpty ? nil : $0 } ?? json,
                    requestJSON: json, firstTokenAt: nil, calls: nil, usage: nil, fragments: [], state: turn.state,
                    reason: nil, error: nil, react: true, generationMetadataAvailable: false)
            }
            return [original] + legacy
        }
    }

    private static func project(
        _ parent: HistoryTurn, id: UUID, date: Date, input: String, requestJSON: String?, firstTokenAt: Date?,
        calls: [HistoryToolCall]?, usage: HistoryTokenUsage?, fragments: [String], state: HistoryTurn.State,
        reason: String?, error: String?, react: Bool, generationMetadataAvailable: Bool = true
    ) -> HistoryTurn {
        HistoryTurn(
            id: id, date: date, user: input,
            request: requestJSON.flatMap { try? JSONDecoder().decode([HistoryMessage].self, from: Data($0.utf8)) }
                ?? (react ? [] : parent.request),
            model: parent.model, maximumOutputTokens: parent.maximumOutputTokens, temperature: parent.temperature,
            modelRequests: nil, firstTokenAt: firstTokenAt, requestJSON: requestJSON, ownerInputID: parent.id,
            isReACT: react,
            generationMetadataAvailable: generationMetadataAvailable,
            continuationRequests: nil, toolDefinitions: parent.toolDefinitions, toolCalls: calls, tokenUsage: usage,
            fragments: fragments, state: state, finishReason: reason, error: error,
            executionError: generationMetadataAvailable ? parent.executionError : nil)
    }

}

extension HistoryTurn {
    public var dateReport: String { generationMetadataAvailable == false ? "" : date.formatted() }
    public var stateReport: String { generationMetadataAvailable == false ? "" : state.rawValue }

    public var outputSummary: String {
        if !raw.isEmpty { return raw }
        guard let calls = toolCalls, !calls.isEmpty else {
            return ""
        }
        return "Tool Call：" + calls.map(\.name).joined(separator: "、")
    }
    public var firstTokenReport: String {
        guard let firstTokenAt else { return "首 token 到达时间：" }
        let delay = max(0, firstTokenAt.timeIntervalSince(date))
        return
            "首 token 到达时间：\(firstTokenAt.formatted(date: .omitted, time: .standard))（距请求开始 \(String(format: "%.3f", delay)) 秒）"
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
            Model round: \(generationMetadataAvailable == false ? "" : id.uuidString)
            Owning input: \(ownerInputID ?? id)
            ReACT: \(isReACT == true)
            Model: \(model)
            Date: \(generationMetadataAvailable == false ? "" : date.ISO8601Format())
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
        if let imageReferences { return Array(imageReferences.filter(\.isValid).prefix(4)) }
        // Compatibility with the prior metadata-only diagnostic representation.
        return Array(
            content.components(separatedBy: "\nImage attachments (bytes omitted): ").dropFirst()
                .flatMap { $0.components(separatedBy: "\n")[0].components(separatedBy: ", ") }
                .compactMap { entry -> HistoryImageReference? in
                    let parts = entry.split(separator: " ")
                    guard parts.count == 4, parts[3] == "bytes", let id = UUID(uuidString: String(parts[0])),
                        let count = Int(parts[2])
                    else { return nil }
                    let reference = HistoryImageReference(id: id, mimeType: String(parts[1]), byteCount: count)
                    return reference.isValid ? reference : nil
                }.prefix(4))
    }
    public var displayContent: String {
        guard !attachedImages.isEmpty else { return content }
        return content.components(separatedBy: "\n").filter {
            !$0.hasPrefix("Image attachments (bytes omitted): ")
        }.joined(separator: "\n")
    }
}

extension HistoryTurn {
    public var displayInput: String {
        guard !attachedImages.isEmpty else { return user }
        return user.components(separatedBy: "\n").filter {
            !$0.hasPrefix("Image attachments (bytes omitted): ")
        }.joined(separator: "\n")
    }
    public var attachedImages: [HistoryImageReference] {
        var seen: Set<UUID> = []
        return Array(request.flatMap(\.attachedImages).filter { seen.insert($0.id).inserted }.prefix(4))
    }
}
