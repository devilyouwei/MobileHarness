import AgentCore
import Foundation
import ModelKit
import StorageChat

/// Title-only inference: never parses Action markup, changes context or executes model output.
public enum ConversationTitleGenerator {
    public static func samplePositions(count: Int) -> [Int] {
        let amount = min(32, count)
        return (0..<amount).map { amount == 1 ? 0 : $0 * (count - 1) / (amount - 1) }
    }
    public static func summarize(
        _ conversation: AssistantConversation, using chat: any ChatCapability, language: String = "en",
        journal: @escaping @Sendable (AssistantModelRequest) async throws -> Void = { _ in },
        transport: @escaping @Sendable (String, ModelRequestLogUpdate) async throws -> Void = { _, _ in }
    ) async throws
        -> String
    {
        guard !conversation.turns.isEmpty else { throw AssistantHistoryError.emptyConversation }
        // Bounded excerpts cover the whole conversation, rather than only its final exchange.
        let selected = samplePositions(count: conversation.turns.count).map { conversation.turns[$0] }
        let templates = try AgentPrompts.titleTemplates(language: language)
        let excerpts = try selected.map {
            try templates.render(
                "title.excerpt",
                variables: [
                    "user": String($0.user.prefix(80)), "assistant": String($0.raw.prefix(80)),
                ])
        }.joined(separator: "\n")
        let request = try ChatRequest(
            messages: [
                .init(role: .system, content: try templates.render("title.system")),
                .init(role: .user, content: try templates.render("title.user", variables: ["excerpts": excerpts])),
            ], temperature: 0)
        let audit = try AgentModelRequestRecording(request)
        let prepared = request
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let journal = TitleRequestJournal(
                    input: excerpts, requestJSON: try audit.snapshot().requestJSON, audit: audit, persist: journal)
                try await journal.begin()
                let invocationID = await journal.id
                var captured = prepared
                captured.transportCapture = audit.transportRecorder { value in
                    if let update = value.transport { try await transport(invocationID, update) }
                }
                do {
                    let session = try await chat.chat(captured)
                    defer { session.cancel() }
                    let result = try await session.withCleanup {
                        try await withTaskCancellationHandler {
                            var finished = false
                            for try await event in session.events {
                                audit.record(event)
                                try Task.checkCancellation()
                                guard !finished else {
                                    throw CapabilityError.invalidRequest("Events after title completion")
                                }
                                switch event {
                                case .text(let delta):
                                    try await journal.append(delta)
                                case .usage(let usage):
                                    await journal.usage(usage)
                                case .toolCall:
                                    throw CapabilityError.invalidRequest("Unexpected title tool call")
                                case .finished(let reason):
                                    guard reason == .stop else {
                                        throw CapabilityError.invalidRequest("Incomplete conversation title")
                                    }
                                    finished = true
                                }
                            }
                            let result = await journal.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard finished, !result.isEmpty, result.count <= 80,
                                !result.contains("\n"), !result.contains("<"), !result.contains(">")
                            else {
                                throw CapabilityError.invalidRequest("Invalid conversation title")
                            }
                            return result
                        } onCancel: {
                            session.cancel()
                        }
                    }
                    try await journal.finish(error: nil)
                    return result
                } catch {
                    let primary = error
                    try await Task { try await journal.finish(error: primary) }.value
                    throw primary
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw CapabilityError.unavailable("Conversation title generation timed out")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}

private actor TitleRequestJournal {
    private var record: AssistantModelRequest
    private let audit: AgentModelRequestRecording
    private let persist: @Sendable (AssistantModelRequest) async throws -> Void
    var id: String { record.id }
    var text: String { record.response }
    init(
        input: String, requestJSON: String, audit: AgentModelRequestRecording,
        persist: @escaping @Sendable (AssistantModelRequest) async throws -> Void
    ) {
        self.audit = audit
        self.persist = persist
        record = .init(id: UUID().uuidString, input: input, requestJSON: requestJSON)
        record.producerMetadata = ["purpose": "title"]
        record.modelRequestStartedAt = Date()
    }
    func begin() async throws { try await persist(record) }
    func append(_ delta: String) throws {
        guard record.response.utf8.count + delta.utf8.count <= 1024 else { throw CapabilityError.eventTooLarge }
        record.response += delta
    }
    func usage(_ value: ChatTokenUsage) {
        record.tokenUsage = .init(
            input: value.input, generated: value.generated, total: value.total, cachedInput: value.cachedInput,
            cacheWriteInput: value.cacheWriteInput)
    }
    func finish(error: (any Error)?) async throws {
        record.state = error == nil ? .completed : error is CancellationError ? .cancelled : .failed
        record.error = error.map(String.init(describing:))
        record.finishReason = error == nil ? "stop" : "error"
        record.modelRequestCompletedAt = Date()
        record.requestParametersJSON = try audit.snapshot().requestJSON
        record.responseEventsJSON = try audit.snapshot().responseJSON
        try await persist(record)
    }
}

extension AgentPrompts {
    static func titleTemplates(language: String = "en") throws -> PromptTemplates {
        try shared.load("Agents/Memory/TitlePrompts.json", language: language)
    }
}
