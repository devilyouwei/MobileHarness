import Foundation
import ModelKit
import ModelKitAppleSpeech
import ModelKitEnergy
import ModelKitMossNano
import ModelKitNemotron
import ModelKitOpenAI
@_spi(ModelAssembly) import ModelKitRuntime
import ModelKitSilero
import ModelKitYOLOPose

#if !targetEnvironment(simulator)
    import ModelKitGemma4
#endif

/// Internal model selection and registration; consumers only receive capability protocols.
public enum ModelKitDefaults {
    public static let mossNano = ModelID("moss-tts-nano")

    private static let process = ProcessModels()
    static let speechSelection = SpeechSelection()
    @available(iOS 27, macOS 27, *)
    public static func unloadSpeechSynthesis(resources: URL) async throws {
        let manager = try await process.manager(resources: resources, cloudChat: nil)
        try await manager.unload(mossNano)
        try await manager.unload(ModelID("apple-synthesis"))
    }
    public static func configureSpeech(recognition: Bool, synthesis: Bool) async {
        await speechSelection.configure(recognition: recognition, synthesis: synthesis)
    }

    /// Every caller receives the same process-wide manager. A different resource root is rejected.
    @available(iOS 27, macOS 27, *)
    public static func manager(resources: URL, cloudChat: OpenAIChatConfiguration? = nil) async throws -> ModelManager {
        try await process.manager(resources: resources, cloudChat: cloudChat)
    }

    /// App supplies metadata and storage without acquiring assembly SPI or registering providers.
    @available(iOS 27, macOS 27, *)
    public static func configureArtifacts(
        resources: URL, catalog: ModelArtifactCatalog, storage: any ModelArtifactStorage,
        downloader: (any ModelArtifactDownloader)? = nil
    ) async throws -> ModelManager {
        let manager = try await process.manager(resources: resources, cloudChat: nil)
        try await manager.configureArtifacts(catalog: catalog, storage: storage, downloader: downloader)
        return manager
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
        try ModelRegistration(
            id: ModelID("chat"), capabilities: [.chat], memoryPolicy: .releaseWhenIdle,
            artifactID: configuration == nil ? "gemma4-e2b" : nil
        ) { context in
            if let configuration {
                return ProvidedCapabilities(chat: try OpenAIChat(context: context, configuration: configuration))
            }
            #if targetEnvironment(simulator)
                return ProvidedCapabilities(chat: UnsupportedChat())
            #else
                let model = try Gemma4Chat(context: context, artifacts: resources.appendingPathComponent("Gemma4"))
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
                ModelRegistration(id: ModelID("silero"), capabilities: [.voiceActivity], artifactID: "silero") {
                    context in
                    ProvidedCapabilities(
                        voiceActivity: try SileroVAD(
                            context: context, artifacts: resources.appendingPathComponent("Silero")))
                })
            try await manager.register(
                ModelRegistration(
                    id: ModelID("nemotron-local"), capabilities: [.recognition], memoryPolicy: .releaseWhenIdle,
                    artifactID: "nemotron"
                ) { context in
                    let model = try NemotronASR(
                        context: context, artifacts: resources.appendingPathComponent("Nemotron"))
                    return ProvidedCapabilities(warmup: { try await model.warmup() }, recognition: model)
                })
            try await manager.register(
                chatRegistration(resources: resources, configuration: cloudChat), defaults: [.chat])
            try await manager.register(
                ModelRegistration(
                    id: mossNano, capabilities: [.synthesis], memoryPolicy: .releaseWhenIdle,
                    artifactID: "moss-tts-nano"
                ) { context in
                    let model = try MossSpeechSynthesis(
                        context: context, artifacts: resources.appendingPathComponent("MossTTSNano"))
                    return ProvidedCapabilities(warmup: { try await model.warmup() }, synthesis: model)
                })
            try await manager.register(
                ModelRegistration(id: ModelID("apple-recognition"), capabilities: [.recognition]) { context in
                    let model = try AppleSpeechRecognition(context: context)
                    return ProvidedCapabilities(warmup: { try await model.warmup() }, recognition: model)
                })
            try await manager.register(
                ModelRegistration(id: ModelID("apple-synthesis"), capabilities: [.synthesis]) { context in
                    ProvidedCapabilities(synthesis: try await AppleSpeechSynthesis(context: context))
                })
            try await manager.register(
                ModelRegistration(id: ModelID("energy-vad"), capabilities: [.voiceActivity]) { context in
                    ProvidedCapabilities(voiceActivity: try EnergyVoiceActivity(context: context))
                })
            let recognition = FallbackRecognition(manager: manager, selection: speechSelection)
            let synthesis = FallbackSynthesis(manager: manager, selection: speechSelection)
            let vad = FallbackVoiceActivity(manager: manager, selection: speechSelection)
            try await manager.register(
                ModelRegistration(id: ModelID("recognition"), capabilities: [.recognition]) { _ in
                    ProvidedCapabilities(warmup: { try await recognition.warmup() }, recognition: recognition)
                }, defaults: [.recognition])
            try await manager.register(
                ModelRegistration(id: ModelID("synthesis"), capabilities: [.synthesis]) { _ in
                    ProvidedCapabilities(warmup: { try await synthesis.warmup() }, synthesis: synthesis)
                }, defaults: [.synthesis])
            try await manager.register(
                ModelRegistration(id: ModelID("voice-activity"), capabilities: [.voiceActivity]) { _ in
                    ProvidedCapabilities(warmup: { try await vad.warmup() }, voiceActivity: vad)
                }, defaults: [.voiceActivity])
            try await manager.register(
                ModelRegistration(
                    id: ModelID("yolo26n-pose"), capabilities: [.pose], memoryPolicy: .releaseWhenIdle,
                    artifactID: "yolo26n-pose"
                ) {
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
        var availability: CapabilityAvailability { .unavailable(reason: "Gemma 4 CoreAI requires a physical device") }
        func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
            throw CapabilityError.unavailable("Gemma 4 CoreAI requires a physical device")
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
