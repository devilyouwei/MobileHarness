import Foundation
import ModelKit
import ModelKitMLXLanguage
import Synchronization

/// An optional local chat provider. Consumers depend on ChatCapability, not this type.
public actor Qwen35Chat: ChatCapability {
    private let resource: ModelResource<MLXLanguageEngine>
    private let root: URL
    private let contextLimit: Int

    /// Composition-only backend configuration. Apply before registering/loading chat.
    public static func configureCache(limitBytes: Int) throws {
        try MLXLanguageEngine.configureCache(limitBytes: limitBytes)
    }

    public init(context: ModelContext, artifacts: URL) throws {
        root = artifacts
        contextLimit = 4096
        resource = try context.resource {
            try Self.requireHardware()
            return try await MLXLanguageEngine(directory: artifacts)
        }
    }

    private static func requireHardware() throws {
        #if targetEnvironment(simulator) || !arch(arm64)
            throw CapabilityError.unavailable("Qwen3.5 MLX requires physical Apple Silicon hardware")
        #endif
    }

    public var availability: CapabilityAvailability {
        do { try Self.requireHardware() } catch { return .unavailable(reason: String(describing: error)) }
        guard FileManager.default.fileExists(atPath: root.path) else {
            return .unavailable(reason: "Qwen35 artifacts are not installed")
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
                    MLXLanguageTurn(role: $0.role.rawValue, content: $0.content)
                })
            guard !tokens.isEmpty, tokens.count <= contextLimit - request.maximumOutputTokens else {
                throw CapabilityError.invalidRequest(
                    "Prompt plus output budget exceeds 4096 tokens; shorten history explicitly")
            }
            try Task.checkCancellation()
            let control = GenerationControl()
            let pair = InferenceSession<ChatEvent>.make(
                context: request.context, limits: try StreamLimits(capacity: 128, maximumEventBytes: 4096),
                estimatedBytes: { $0.estimatedBytes },
                onTermination: { reason in
                    if case .finished = reason { return }
                    control.cancel()
                })
            let resource = resource
            let emitter = pair.emitter
            let task = Task {
                do {
                    let stopped = try await lease.model.generate(
                        tokens: tokens, maximumTokens: request.maximumOutputTokens, temperature: request.temperature,
                        stopTokens: [248044, 248046]
                    ) { delta in
                        try emitter.yield(.text(delta))
                    }
                    try Task.checkCancellation()
                    await resource.release(lease.id)
                    try emitter.yield(.finished(stopped ? .stop : .lengthLimit))
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
        guard request.messages.count <= 64, request.maximumOutputTokens <= 1024,
            request.messages.reduce(0, { $0 + $1.content.utf8.count }) <= 65536,
            request.messages.last?.role == .user,
            request.messages.allSatisfy({ !$0.content.isEmpty })
        else {
            throw CapabilityError.invalidRequest(
                "Qwen35 requires 1–64 nonempty messages ending in user, at most 64 KiB, and 1–1024 output tokens")
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
