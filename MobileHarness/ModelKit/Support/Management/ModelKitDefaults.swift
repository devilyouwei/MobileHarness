import Foundation
import ModelKit
import ModelKitOpenAI
@_spi(ModelAssembly) import ModelKitRuntime

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

    /// Registers lightweight factories without loading weights or requesting device permissions.
    @available(iOS 27, macOS 27, *)
    static func assemble(resources: URL, cloudChat: OpenAIChatConfiguration?) async throws -> ModelManager {
        let manager = try ModelManager()
        do {
            try await registerSpeechModels(manager: manager, resources: resources)
            try await manager.register(
                chatRegistration(resources: resources, configuration: cloudChat), defaults: [.chat])
            try await registerSpeechDefaults(manager: manager)
            try await registerVision(manager: manager, resources: resources)
            return manager
        } catch {
            await manager.shutdown()
            throw error
        }
    }
}

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
