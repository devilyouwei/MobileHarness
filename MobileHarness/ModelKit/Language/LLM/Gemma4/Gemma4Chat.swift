import Foundation
import ModelKit

/// An optional local chat provider. Consumers depend on ChatCapability, not this type.
@available(iOS 27, macOS 27, *)
public actor Gemma4Chat: ChatCapability {
    private let resource: ModelResource<GemmaLanguageEngine>
    private let root: URL

    public init(context: ModelContext, artifacts: URL) throws {
        root = artifacts
        resource = try context.resource {
            try Self.requireHardware()
            return try await GemmaLanguageEngine(directory: artifacts)
        }
    }

    private static func requireHardware() throws {
        #if targetEnvironment(simulator) || !arch(arm64)
            throw CapabilityError.unavailable("Gemma 4 CoreAI requires physical Apple Silicon hardware")
        #endif
    }

    public var availability: CapabilityAvailability {
        do { try Self.requireHardware() } catch { return .unavailable(reason: String(describing: error)) }
        guard FileManager.default.fileExists(atPath: root.path) else {
            return .unavailable(reason: "Gemma4 artifacts are not installed")
        }
        return .available
    }
    public func warmup() async throws {
        let session = try await chat(
            ChatRequest(messages: [.init(role: .user, content: "Hi")], maximumOutputTokens: 1, temperature: 0))
        defer { session.cancel() }
        for try await _ in session.events {}
    }

    public func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        try Self.validate(request)
        try Task.checkCancellation()
        let lease = try await resource.acquire()
        do {
            let prepared = try await GemmaContextBudget.prepare(request, contextLimit: lease.model.contextLimit) {
                messages in
                await lease.model.tokenize(
                    messages.map { GemmaLanguageTurn(role: $0.role.rawValue, content: $0.content) })
            }
            let tokens = prepared.tokens
            let maximumTokens = prepared.maximumOutputTokens
            try Task.checkCancellation()
            let control = InferenceTaskControl()
            let pair = InferenceSession<ChatEvent>.make(
                context: request.context, limits: try StreamLimits(capacity: 4096, maximumEventBytes: 4096),
                estimatedBytes: { $0.estimatedBytes },
                onTermination: { reason in
                    if case .finished = reason { return }
                    control.cancel()
                }, waitForCompletion: { await control.waitForCompletion() })
            let resource = resource
            let emitter = pair.emitter
            let task = Task {
                defer { control.finish() }
                do {
                    request.timing?.start()
                    let generation = try await lease.model.generate(
                        tokens: tokens, maximumTokens: maximumTokens, temperature: request.temperature,
                        stopTokens: []
                    ) { delta in
                        request.timing?.recordText(delta)
                        try emitter.yield(.text(delta))
                    }
                    try Task.checkCancellation()
                    await resource.release(lease.id)
                    try emitter.yield(
                        .usage(
                            try ChatTokenUsage(
                                input: tokens.count, generated: generation.generatedTokens,
                                total: tokens.count + generation.generatedTokens)))
                    try emitter.yield(.finished(generation.stopped ? .stop : .lengthLimit))
                    emitter.finish()
                } catch {
                    await resource.release(lease.id)
                    emitter.fail(error)
                }
            }
            try control.install(task)
            await resource.setCancellation(lease.id) { [weak session = pair.session] in session?.cancel() }
            return pair.session
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }

    static func validate(_ request: ChatRequest) throws {
        guard request.messages.allSatisfy({ $0.images?.isEmpty ?? true }) else {
            throw CapabilityError.invalidRequest("Local image understanding is unavailable")
        }
        guard request.tools.isEmpty,
            request.messages.allSatisfy({ $0.role != .tool && $0.toolCalls.isEmpty && $0.toolCallID == nil })
        else {
            throw CapabilityError.invalidRequest("Local native tool calls are unavailable")
        }
        guard request.messages.count <= 64,
            request.messages.reduce(0, { $0 + $1.content.utf8.count }) <= 65536
        else {
            throw CapabilityError.invalidRequest(
                "Gemma4 source request exceeds 64 messages or 64 KiB"
            )
        }
        // Identify the current turn before filtering: an empty user must never fall back to an older input.
        guard let current = request.messages.last(where: { $0.role != .system }), current.role == .user else {
            throw CapabilityError.invalidRequest("Gemma4 requires the last non-system message to be user")
        }
        guard hasText(current) else {
            throw CapabilityError.invalidRequest("Gemma4 current user input is empty or whitespace")
        }
    }

    private static func hasText(_ message: ChatMessage) -> Bool {
        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// System-free local diagnostic inference; the caller's original request remains unchanged.
    static func renderedMessages(_ request: ChatRequest) -> [ChatMessage] {
        request.messages.filter { $0.role != .system && hasText($0) }
    }
}

/// Provider-only inference copy. The caller's request, stored history and cloud adapters are unchanged.
@available(iOS 27, macOS 27, *)
enum GemmaContextBudget {
    static let contextLimit = 4096
    static let defaultOutputTokens = 1024
    static let maximumMessages = 5
    typealias Tokenize = @Sendable ([ChatMessage]) async throws -> [Int]

    struct Prepared: Sendable {
        let messages: [ChatMessage]
        let tokens: [Int]
        let maximumOutputTokens: Int
    }

    /// Pinned CoreAI's iOS dynamic-KV guard (apple/coreai-models#124) is tighter than the graph window.
    static func effectiveContextLimit(modelLimit: Int, isIOS: Bool) -> Int {
        min(modelLimit, isIOS ? 1024 : contextLimit)
    }

    static func prepare(_ request: ChatRequest, contextLimit: Int = contextLimit, tokenize: Tokenize) async throws
        -> Prepared
    {
        try Gemma4Chat.validate(request)
        guard (2...Self.contextLimit).contains(contextLimit) else {
            throw CapabilityError.invalidRequest("Invalid local backend context limit: \(contextLimit)")
        }
        let normalized = Gemma4Chat.renderedMessages(request)
        var history = Array(normalized.suffix(maximumMessages))
        guard let current = history.last else { throw CapabilityError.invalidRequest("Missing current local input") }
        let minimum = try await encode([current], tokenize: tokenize)
        guard !minimum.isEmpty, minimum.count < contextLimit else {
            throw CapabilityError.invalidRequest(
                "Current input alone leaves no generation space in the local \(contextLimit)-token window")
        }
        let reserve = min(defaultOutputTokens, contextLimit / 4)
        let output = min(request.maximumOutputTokens ?? reserve, contextLimit - minimum.count)
        let inputLimit = contextLimit - output
        var tokens = try await encode(history, tokenize: tokenize)
        while tokens.count > inputLimit, history.count > 1 {
            history.removeFirst()
            tokens = try await encode(history, tokenize: tokenize)
        }
        let maximumOutput = min(request.maximumOutputTokens ?? contextLimit, contextLimit - tokens.count)
        guard !tokens.isEmpty, maximumOutput > 0, tokens.count <= contextLimit - maximumOutput else {
            throw CapabilityError.invalidRequest("Local prompt and generation exceed the \(contextLimit)-token window")
        }
        return Prepared(messages: history, tokens: tokens, maximumOutputTokens: maximumOutput)
    }

    private static func encode(_ messages: [ChatMessage], tokenize: Tokenize) async throws -> [Int] {
        try Task.checkCancellation()
        let result = try await tokenize(messages)
        try Task.checkCancellation()
        return result
    }
}
