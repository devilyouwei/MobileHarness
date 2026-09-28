import Foundation
import ModelKit
import ModelKitMossNano
import ModelKitNemotron
import ModelKitOpenAI
@_spi(ModelAssembly) import ModelKitRuntime
import ModelKitSilero
import ModelKitYOLOPose

#if !targetEnvironment(simulator)
    import ModelKitQwen35
#endif

/// Internal model selection and registration; consumers only receive capability protocols.
public enum ModelKitDefaults {
    public static let mossNano = ModelID("moss-tts-nano")

    private static let process = ProcessModels()

    /// Every caller receives the same process-wide manager. A different resource root is rejected.
    @available(iOS 27, macOS 27, *)
    public static func manager(resources: URL, cloudChat: OpenAIChatConfiguration? = nil) async throws -> ModelManager {
        try await process.manager(resources: resources, cloudChat: cloudChat)
    }

    /// Explicit settings update; preserves the process manager and unrelated model instances.
    @available(iOS 27, macOS 27, *)
    public static func configureChat(resources: URL, configuration: OpenAIChatConfiguration?) async throws {
        try await process.configureChat(resources: resources, configuration: configuration)
    }

    @available(iOS 27, macOS 27, *)
    fileprivate static func chatRegistration(resources: URL, configuration: OpenAIChatConfiguration?) throws
        -> ModelRegistration
    {
        try ModelRegistration(id: ModelID("chat"), capabilities: [.chat], memoryPolicy: .releaseWhenIdle) { context in
            if let configuration {
                return ProvidedCapabilities(chat: try OpenAIChat(context: context, configuration: configuration))
            }
            #if targetEnvironment(simulator)
                return ProvidedCapabilities(chat: UnsupportedChat())
            #else
                try Qwen35Chat.configureCache(limitBytes: 64 * 1024 * 1024)
                let model = try Qwen35Chat(context: context, artifacts: resources.appendingPathComponent("Qwen35"))
                return ProvidedCapabilities(warmup: { try await model.warmup() }, chat: model)
            #endif
        }
    }

    /// Registers lightweight factories without loading weights or requesting device permissions.
    @available(iOS 27, macOS 27, *)
    fileprivate static func assemble(resources: URL, cloudChat: OpenAIChatConfiguration?) async throws -> ModelManager {
        let manager = ModelManager()
        do {
            try await manager.register(
                ModelRegistration(id: ModelID("silero"), capabilities: [.voiceActivity]) { context in
                    ProvidedCapabilities(
                        voiceActivity: try SileroVAD(
                            context: context, artifacts: resources.appendingPathComponent("Silero")))
                }, defaults: [.voiceActivity])
            try await manager.register(
                ModelRegistration(
                    id: ModelID("recognition"), capabilities: [.recognition], memoryPolicy: .releaseWhenIdle
                ) { context in
                    #if targetEnvironment(simulator)
                        return ProvidedCapabilities(recognition: UnsupportedRecognition())
                    #else
                        let model = try NemotronASR(
                            context: context, artifacts: resources.appendingPathComponent("Nemotron"))
                        return ProvidedCapabilities(warmup: { try await model.warmup() }, recognition: model)
                    #endif
                }, defaults: [.recognition])
            try await manager.register(
                chatRegistration(resources: resources, configuration: cloudChat), defaults: [.chat])
            try await manager.register(
                ModelRegistration(id: mossNano, capabilities: [.synthesis], memoryPolicy: .releaseWhenIdle) { context in
                    let model = try MossSpeechSynthesis(
                        context: context, artifacts: resources.appendingPathComponent("MossTTSNano"))
                    return ProvidedCapabilities(warmup: { try await model.warmup() }, synthesis: model)
                }, defaults: [.synthesis])
            try await manager.register(
                ModelRegistration(id: ModelID("yolo26n-pose"), capabilities: [.pose], memoryPolicy: .releaseWhenIdle) {
                    context in
                    ProvidedCapabilities(
                        pose: try YOLOPose(context: context, artifacts: resources.appendingPathComponent("YOLOPose")))
                }, defaults: [.pose])
            return manager
        } catch {
            await manager.shutdown()
            throw error
        }
    }
}

#if targetEnvironment(simulator)
    private struct UnsupportedChat: ChatCapability {
        var availability: CapabilityAvailability { .unavailable(reason: "Qwen3.5 MLX requires a physical device") }
        func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
            throw CapabilityError.unavailable("Qwen3.5 MLX requires a physical device")
        }
    }
    private struct UnsupportedRecognition: SpeechRecognitionCapability {
        var availability: CapabilityAvailability { .unavailable(reason: "Nemotron ASR requires a physical device") }
        func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
            throw CapabilityError.unavailable("Nemotron ASR requires a physical device")
        }
    }
#endif

public enum ModelKitConfigurationError: Error, Equatable, Sendable {
    case resourceDirectoryConflict
    case cloudConfigurationConflict
}

private actor ProcessModels {
    private var root: URL?
    private var cloudChat: OpenAIChatConfiguration?
    private var assembly: Task<ModelManager, Error>?
    private var waiters = 0
    private var updating = false

    @available(iOS 27, macOS 27, *)
    func configureChat(resources: URL, configuration: OpenAIChatConfiguration?) async throws {
        guard !updating else { throw CapabilityError.inputBusy }
        updating = true
        defer { updating = false }
        let manager = try await manager(resources: resources, cloudChat: nil)
        guard cloudChat != configuration else { return }
        try await manager.replace(ModelKitDefaults.chatRegistration(resources: resources, configuration: configuration))
        cloudChat = configuration
    }

    @available(iOS 27, macOS 27, *)
    func manager(resources: URL, cloudChat: OpenAIChatConfiguration?) async throws -> ModelManager {
        try Task.checkCancellation()
        let requested = resources.standardizedFileURL.resolvingSymlinksInPath()
        if let root, root != requested { throw ModelKitConfigurationError.resourceDirectoryConflict }
        if assembly != nil, let cloudChat, self.cloudChat != cloudChat {
            throw ModelKitConfigurationError.cloudConfigurationConflict
        }
        guard waiters < 32 else { throw CapabilityError.inputBusy }
        waiters += 1
        defer { waiters -= 1 }
        if assembly == nil {
            root = requested
            self.cloudChat = cloudChat
            // Stored before suspension: simultaneous callers cannot create another manager.
            assembly = Task { try await ModelKitDefaults.assemble(resources: requested, cloudChat: cloudChat) }
        }
        guard let assembly else { throw CapabilityError.sessionClosed }
        let manager = try await assembly.value
        try Task.checkCancellation()
        return manager
    }
}
