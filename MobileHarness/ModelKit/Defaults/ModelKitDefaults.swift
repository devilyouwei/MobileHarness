import Foundation
import ModelKit
import ModelKitAppleSpeech
import ModelKitKokoro
import ModelKitNemotron
@_spi(ModelAssembly) import ModelKitRuntime
import ModelKitSilero

#if !targetEnvironment(simulator)
    import ModelKitQwen35
#endif

/// Internal model selection and registration; consumers only receive capability protocols.
public enum ModelKitDefaults {
    public static let kokoro = ModelID("kokoro")

    private static let process = ProcessModels()

    /// Every caller receives the same process-wide manager. A different resource root is rejected.
    @available(iOS 27, macOS 27, *)
    public static func manager(resources: URL) async throws -> ModelManager {
        try await process.manager(resources: resources)
    }

    /// Registers lightweight factories without loading weights or requesting device permissions.
    @available(iOS 27, macOS 27, *)
    fileprivate static func assemble(resources: URL) async throws -> ModelManager {
        let manager = ModelManager()
        do {
            #if !targetEnvironment(simulator)
                try Qwen35Chat.configureCache(limitBytes: 64 * 1024 * 1024)
            #endif
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
                ModelRegistration(id: ModelID("chat"), capabilities: [.chat], memoryPolicy: .releaseWhenIdle) {
                    context in
                    #if targetEnvironment(simulator)
                        return ProvidedCapabilities(chat: UnsupportedChat())
                    #else
                        let model = try Qwen35Chat(
                            context: context, artifacts: resources.appendingPathComponent("Qwen35"))
                        return ProvidedCapabilities(warmup: { try await model.warmup() }, chat: model)
                    #endif
                }, defaults: [.chat])
            try await manager.register(
                ModelRegistration(id: ModelID("apple-speech"), capabilities: [.synthesis]) { context in
                    ProvidedCapabilities(synthesis: try await AppleSpeechSynthesis(context: context))
                }, defaults: [.synthesis])
            try await manager.register(
                ModelRegistration(id: kokoro, capabilities: [.synthesis], memoryPolicy: .releaseWhenIdle) { context in
                    ProvidedCapabilities(
                        synthesis: try KokoroSpeechSynthesis(
                            context: context, artifacts: resources.appendingPathComponent("Kokoro")))
                })
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
}

private actor ProcessModels {
    private var root: URL?
    private var assembly: Task<ModelManager, Error>?
    private var waiters = 0

    @available(iOS 27, macOS 27, *)
    func manager(resources: URL) async throws -> ModelManager {
        try Task.checkCancellation()
        let requested = resources.standardizedFileURL.resolvingSymlinksInPath()
        if let root, root != requested { throw ModelKitConfigurationError.resourceDirectoryConflict }
        guard waiters < 32 else { throw CapabilityError.inputBusy }
        waiters += 1
        defer { waiters -= 1 }
        if assembly == nil {
            root = requested
            // Stored before suspension: simultaneous callers cannot create another manager.
            assembly = Task { try await ModelKitDefaults.assemble(resources: requested) }
        }
        guard let assembly else { throw CapabilityError.sessionClosed }
        let manager = try await assembly.value
        try Task.checkCancellation()
        return manager
    }
}
