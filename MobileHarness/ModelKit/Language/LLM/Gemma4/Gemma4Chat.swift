import Foundation
import ModelKit
import ModelKitCoreAI
import Synchronization

/// An optional local chat provider. Consumers depend on ChatCapability, not this type.
@available(iOS 27, macOS 27, *)
public actor Gemma4Chat: ChatCapability {
    private let resource: ModelResource<CoreAILanguageEngine>
    private let root: URL
    private let contextLimit: Int

    public init(context: ModelContext, artifacts: URL) throws {
        root = artifacts
        contextLimit = 4096
        resource = try context.resource {
            try Self.requireHardware()
            return try await CoreAILanguageEngine(directory: artifacts)
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
            let tokens = try await lease.model.tokenize(
                request.messages.map {
                    CoreAILanguageTurn(role: $0.role.rawValue, content: $0.content)
                })
            let maximumTokens = request.maximumOutputTokens ?? (contextLimit - tokens.count)
            guard !tokens.isEmpty, maximumTokens > 0, maximumTokens <= contextLimit,
                tokens.count <= contextLimit - maximumTokens
            else {
                throw CapabilityError.invalidRequest(
                    "Prompt plus output budget exceeds 4096 tokens; shorten history explicitly")
            }
            try Task.checkCancellation()
            let control = GenerationControl()
            let pair = InferenceSession<ChatEvent>.make(
                context: request.context, limits: try StreamLimits(capacity: 4096, maximumEventBytes: 4096),
                estimatedBytes: { $0.estimatedBytes },
                onTermination: { reason in
                    if case .finished = reason { return }
                    control.cancel()
                })
            let resource = resource
            let emitter = pair.emitter
            let task = Task {
                do {
                    let generation = try await lease.model.generate(
                        tokens: tokens, maximumTokens: maximumTokens, temperature: request.temperature,
                        stopTokens: []
                    ) { delta in
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
            control.install(task)
            await resource.setCancellation(lease.id) { [weak session = pair.session] in session?.cancel() }
            return pair.session
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }

    static func validate(_ request: ChatRequest) throws {
        guard request.tools.isEmpty else {
            throw CapabilityError.invalidRequest("Local native tool calls are unavailable")
        }
        guard request.messages.count <= 64,
            request.messages.reduce(0, { $0 + $1.content.utf8.count }) <= 65536,
            request.messages.last?.role == .user,
            request.messages.allSatisfy({ !$0.content.isEmpty })
        else {
            throw CapabilityError.invalidRequest(
                "Gemma4 requires 1–64 nonempty messages ending in user, at most 64 KiB, and an output budget fitting the local context window"
            )
        }
        guard !request.messages.dropFirst().contains(where: { $0.role == .system }) else {
            throw CapabilityError.invalidRequest("System instructions must be the first message")
        }
    }
}

/// Handles cancel-before-install without retaining the session or holding a lock while cancelling.
private final class GenerationControl: Sendable {
    private struct State {
        var cancelled = false
        var task: Task<Void, Never>?
    }
    private let state = Mutex(State())
    func install(_ task: Task<Void, Never>) {
        let cancelled = state.withLock { value in
            value.task = task
            return value.cancelled
        }
        if cancelled { task.cancel() }
    }
    func cancel() {
        let task = state.withLock { value in
            value.cancelled = true
            return value.task
        }
        task?.cancel()
    }
}
