import Foundation
import ModelKit
import ModelKitOpenAI
@_spi(ModelAssembly) import ModelKitRuntime

public protocol ModelResourceControlling: Sendable {
    func load() async throws
    func warmup() async throws
    func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) async throws
    func unload() async throws
    func status() async throws -> ModelState
}
public protocol ModelLanguageProviding: ChatCapability, ModelResourceControlling {
    func configure(_ configuration: OpenAIChatConfiguration?) async throws
}
public protocol ModelSpeechProviding: Sendable {
    var recognition: any SpeechRecognitionCapability { get }
    var synthesis: any SpeechSynthesisCapability { get }
    var voiceActivity: any VoiceActivityCapability { get }
    func configure(recognition: Bool, synthesis: Bool) async throws
    func load(_ capability: ProvidedCapability) async throws
    func warmup(_ capability: ProvidedCapability) async throws
    func warmup(_ capability: ProvidedCapability, reportLoading: @escaping @Sendable (Bool) async -> Void) async throws
    func unload(_ capability: ProvidedCapability) async throws
    func status(_ capability: ProvidedCapability) async throws -> ModelState
}
public protocol ModelVisionProviding: PoseCapability, ModelResourceControlling {}
public protocol ModelArtifactsManaging: Sendable {
    func prepare() async throws
    func artifactSnapshots() async throws -> [ModelArtifactSnapshot]
    func downloadArtifact(_ id: String, source: ModelDownloadSource) async throws
    func cancelArtifact(_ id: String) async throws
    func removeArtifact(_ id: String, quiesce: @escaping @Sendable () async -> Void) async throws
}
public struct ModelArtifactConfiguration: Sendable {
    public let catalog: ModelArtifactCatalog
    public let storage: any ModelArtifactStorage
    public let downloader: (any ModelArtifactDownloader)?
    public init(
        catalog: ModelArtifactCatalog, storage: any ModelArtifactStorage,
        downloader: (any ModelArtifactDownloader)? = nil
    ) {
        self.catalog = catalog
        self.storage = storage
        self.downloader = downloader
    }
}

/// App-owned root. Child ports are stable and never resolve a global or replacement root.
@MainActor public final class ModelContainer {
    public let language: ModelLanguageContainer
    public let speech: ModelSpeechContainer
    public let vision: ModelVisionContainer
    public let artifacts: ModelArtifactsContainer
    private let scope: ModelScope
    private let admission: InferenceAdmission
    private var started = false
    private var stopped = false
    private var suspension: Task<Void, Never>?
    private var shutdown: Task<Void, Error>?
    public init(
        resources: URL,
        prepareArtifacts: (@Sendable () async throws -> ModelArtifactConfiguration)? = nil,
        onFailure: @escaping @Sendable (String, String, any Error) -> Void = { _, _, _ in }
    ) {
        let admission = InferenceAdmission(open: false)
        let scope = ModelScope(
            resources: resources, admission: admission, prepareArtifacts: prepareArtifacts, onFailure: onFailure)
        self.admission = admission
        self.scope = scope
        language = ModelLanguageContainer(scope: scope)
        speech = ModelSpeechContainer(scope: scope)
        vision = ModelVisionContainer(scope: scope)
        artifacts = ModelArtifactsContainer(scope: scope)
    }
    public func start() async throws(ModelFailure) {
        do {
            guard !stopped else { throw InferenceAdmissionError.stopped }
            if started { return }
            _ = try await scope.prepare()
            guard !stopped else { throw InferenceAdmissionError.stopped }
            started = true
            // Foreground is granted by the lifecycle graph, after all required starts succeed.
        } catch {
            throw scope.report("root", "start", error)
        }
    }
    public func invalidate() {
        admission.close()
        guard suspension == nil else { return }
        suspension = Task { [scope] in await scope.suspend() }
    }
    public func setForeground(_ active: Bool) async throws(ModelFailure) {
        do {
            if !active { invalidate() }
            await suspension?.value
            if active {
                guard started, !stopped else { throw InferenceAdmissionError.stopped }
                suspension = nil
                try admission.resume()
            }
        } catch {
            throw scope.report("root", "setForeground", error)
        }
    }
    public func handleMemoryPressure() async { await scope.memoryPressure() }
    public func stop() async throws(ModelFailure) {
        do {
            if let shutdown { return try await shutdown.value }
            stopped = true
            admission.close(terminal: true)
            let suspension = suspension
            let task = Task { [scope] in
                await suspension?.value
                try await scope.stop()
            }
            shutdown = task
            try await task.value
        } catch {
            throw scope.report("root", "stop", error)
        }
    }
}

private actor ModelScope {
    let resources: URL
    let admission: InferenceAdmission
    let selection = SpeechSelection()
    let failure: @Sendable (String, String, any Error) -> Void
    private let prepareArtifacts: (@Sendable () async throws -> ModelArtifactConfiguration)?
    private var assembly: Task<ModelManager, Error>?
    private var closed = false
    private var waiters = 0
    private var updating = false
    private var cloudChat: OpenAIChatConfiguration?
    init(
        resources: URL, admission: InferenceAdmission,
        prepareArtifacts: (@Sendable () async throws -> ModelArtifactConfiguration)?,
        onFailure: @escaping @Sendable (String, String, any Error) -> Void
    ) {
        self.resources = resources
        self.admission = admission
        self.prepareArtifacts = prepareArtifacts
        failure = onFailure
    }
    func prepare() async throws -> ModelManager {
        try admission.checkAlive()
        guard !closed else { throw InferenceAdmissionError.stopped }
        guard waiters < 32 else { throw CapabilityError.inputBusy }
        waiters += 1
        defer { waiters -= 1 }
        if assembly == nil {
            assembly = Task { [resources, selection, admission, prepareArtifacts] in
                guard #available(iOS 27, macOS 27, *) else {
                    throw CapabilityError.unavailable("Model assembly requires OS 27")
                }
                let manager = try await DefaultModelAssembly.assemble(
                    resources: resources, selection: selection, admission: admission)
                do {
                    if let prepareArtifacts {
                        let configuration = try await prepareArtifacts()
                        try await manager.configureArtifacts(
                            catalog: configuration.catalog, storage: configuration.storage,
                            downloader: configuration.downloader)
                        _ = try await manager.artifactSnapshots()
                    }
                    return manager
                } catch {
                    let primary = error
                    do { try await manager.releaseArtifacts() } catch {
                        await manager.shutdown()
                        throw ModelFailure(
                            component: "root", operation: "prepare", underlying: primary, cleanupErrors: [error])
                    }
                    await manager.shutdown()
                    throw primary
                }
            }
        }
        guard let assembly else { throw InferenceAdmissionError.stopped }
        let manager = try await assembly.value
        try Task.checkCancellation()
        guard !closed else { throw InferenceAdmissionError.stopped }
        return manager
    }
    @discardableResult nonisolated func report(
        _ component: String, _ operation: String, _ error: any Error,
        fileID: String = #fileID, function: String = #function, line: UInt = #line
    ) -> ModelFailure {
        let value = ModelFailure(
            component: component, operation: operation, underlying: error,
            fileID: fileID, function: function, line: line)
        failure(value.component, value.operation, value)
        return value
    }
    func perform<T: Sendable>(
        _ component: String, _ operation: String, inference: Bool = true,
        _ work: @Sendable (ModelManager) async throws -> T
    ) async throws -> T {
        do {
            let generation = inference ? try admission.check() : nil
            let result = try await work(prepare())
            if let generation { try admission.validate(generation) }
            guard !closed else { throw InferenceAdmissionError.stopped }
            return result
        } catch {
            report(component, operation, error)
            throw error
        }
    }
    func configureChat(_ configuration: OpenAIChatConfiguration?) async throws {
        do {
            guard #available(iOS 27, macOS 27, *) else {
                throw CapabilityError.unavailable("Model configuration requires OS 27")
            }
            guard !updating else { throw CapabilityError.inputBusy }
            updating = true
            defer { updating = false }
            try await perform("language", "configure", inference: false) { [resources, cloudChat] manager in
                if cloudChat != configuration {
                    try await manager.replace(
                        DefaultModelAssembly.chatRegistration(resources: resources, configuration: configuration))
                }
            }
            cloudChat = configuration
        } catch {
            report("language", "configure", error)
            throw error
        }
    }
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws {
        do {
            try admission.checkAlive()
            guard !closed else { throw InferenceAdmissionError.stopped }
            await selection.configure(recognition: recognition, synthesis: synthesis)
        } catch {
            report("speech", "configure", error)
            throw error
        }
    }
    func selectedSpeech(_ capability: ProvidedCapability, manager: ModelManager) async throws -> ModelID {
        switch capability {
        case .recognition:
            return try await selection.resolve(
                manager: manager, artifact: "nemotron", local: ModelID("nemotron-local"),
                system: ModelID("apple-recognition"), capability: capability)
        case .synthesis:
            return try await selection.resolve(
                manager: manager, artifact: "moss-tts-nano", local: DefaultModelAssembly.mossNano,
                system: ModelID("apple-synthesis"), capability: capability)
        case .voiceActivity:
            return try await selection.resolve(
                manager: manager, artifact: "silero", local: ModelID("silero"), system: ModelID("energy-vad"),
                capability: capability)
        default: throw CapabilityError.invalidRequest("Not a speech capability")
        }
    }
    func suspend() async {
        if let assembly, let manager = try? await assembly.value { await manager.suspend() }
    }
    func memoryPressure() async {
        if !closed, let assembly, let manager = try? await assembly.value { _ = await manager.handleMemoryPressure() }
    }
    func stop() async throws {
        closed = true
        assembly?.cancel()
        guard let assembly else { return }
        let manager: ModelManager
        do { manager = try await assembly.value } catch let error as CancellationError {
            report("root", "stop.assembly", error)
            return
        } catch {
            throw error
        }
        await manager.suspend()
        var failure: (any Error)?
        do { try await manager.releaseArtifacts() } catch {
            failure = error
            report("artifacts", "stop", error)
        }
        await manager.shutdown()
        self.assembly = nil
        cloudChat = nil
        await selection.configure(recognition: false, synthesis: false)
        if let failure { throw failure }
    }
}

public final class ModelLanguageContainer: ModelLanguageProviding, Sendable {
    private let scope: ModelScope
    fileprivate init(scope: ModelScope) { self.scope = scope }
    public var availability: CapabilityAvailability {
        get async {
            do { return try await scope.perform("language", "availability") { try await $0.availability(.chat) } } catch
            { return .unavailable(reason: String(describing: error)) }
        }
    }
    public var supportsToolCalls: Bool {
        get async {
            (try? await scope.perform("language", "toolSupport") {
                await (try await $0.get(.chat, load: false)).supportsToolCalls
            }) ?? false
        }
    }
    public var supportsImages: Bool {
        get async {
            (try? await scope.perform("language", "imageSupport") {
                await (try await $0.get(.chat, load: false)).supportsImages
            }) ?? false
        }
    }
    public func configure(_ configuration: OpenAIChatConfiguration?) async throws {
        try await scope.configureChat(configuration)
    }
    public func warmup() async throws { try await warmup(reportLoading: { _ in }) }
    public func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) async throws {
        try await scope.perform("language", "warmup") { try await $0.warmup(.chat, reportLoading: reportLoading) }
    }
    public func load() async throws { try await scope.perform("language", "load") { try await $0.load(.chat) } }
    public func unload() async throws {
        try await scope.perform("language", "unload", inference: false) { try await $0.unload(.chat) }
    }
    public func status() async throws -> ModelState {
        try await scope.perform("language", "status", inference: false) { try await $0.status(.chat) }
    }
    public func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let session = try await scope.perform("language", "chat") {
            try await (try await $0.get(.chat, load: false)).chat(request)
        }
        session.observeFailure { [scope] in scope.report("language", "chat.stream", $0) }
        return session
    }
}

public final class ModelSpeechContainer: ModelSpeechProviding, Sendable {
    private let scope: ModelScope
    public let recognition: any SpeechRecognitionCapability
    public let synthesis: any SpeechSynthesisCapability
    public let voiceActivity: any VoiceActivityCapability
    fileprivate init(scope: ModelScope) {
        self.scope = scope
        recognition = RecognitionPort(scope: scope)
        synthesis = SynthesisPort(scope: scope)
        voiceActivity = VoiceActivityPort(scope: scope)
    }
    public func configure(recognition: Bool, synthesis: Bool) async throws {
        try await scope.configureSpeech(recognition: recognition, synthesis: synthesis)
    }
    public func warmup(_ capability: ProvidedCapability) async throws {
        try await warmup(capability, reportLoading: { _ in })
    }
    public func warmup(_ capability: ProvidedCapability, reportLoading: @escaping @Sendable (Bool) async -> Void)
        async throws
    {
        guard [.recognition, .synthesis, .voiceActivity].contains(capability) else {
            throw CapabilityError.invalidRequest("Not a speech capability")
        }
        try await scope.perform("speech", "warmup") { [scope] manager in
            try await manager.warmup(scope.selectedSpeech(capability, manager: manager), reportLoading: reportLoading)
        }
    }
    public func load(_ capability: ProvidedCapability) async throws {
        try await scope.perform("speech", "load") { [scope] manager in
            try await manager.load(scope.selectedSpeech(capability, manager: manager))
        }
    }
    public func status(_ capability: ProvidedCapability) async throws -> ModelState {
        try await scope.perform("speech", "status", inference: false) { [scope] manager in
            try await manager.status(scope.selectedSpeech(capability, manager: manager))
        }
    }
    public func unload(_ capability: ProvidedCapability) async throws {
        let ids: [String]
        switch capability {
        case .recognition: ids = ["nemotron-local", "apple-recognition"]
        case .synthesis: ids = ["moss-tts-nano", "apple-synthesis"]
        case .voiceActivity: ids = ["silero", "energy-vad"]
        default: throw CapabilityError.invalidRequest("Not a speech capability")
        }
        try await scope.perform("speech", "unload", inference: false) { manager in
            for id in ids { try await manager.unload(ModelID(id)) }
        }
    }
}
private struct RecognitionPort: SpeechRecognitionCapability {
    let scope: ModelScope
    var availability: CapabilityAvailability {
        get async {
            do {
                return try await scope.perform("speech", "recognition.availability") {
                    try await $0.availability(.recognition)
                }
            } catch { return .unavailable(reason: String(describing: error)) }
        }
    }
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        let session = try await scope.perform("speech", "recognition") {
            try await (try await $0.get(.recognition, load: false)).transcribe(request)
        }
        session.output.observeFailure { [scope] in scope.report("speech", "recognition.stream", $0) }
        return session
    }
}
private struct SynthesisPort: SpeechSynthesisCapability {
    let scope: ModelScope
    var availability: CapabilityAvailability {
        get async {
            do {
                return try await scope.perform("speech", "synthesis.availability") {
                    try await $0.availability(.synthesis)
                }
            } catch { return .unavailable(reason: String(describing: error)) }
        }
    }
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        let session = try await scope.perform("speech", "synthesis") {
            try await (try await $0.get(.synthesis, load: false)).synthesize(request)
        }
        session.observeFailure { [scope] in scope.report("speech", "synthesis.stream", $0) }
        return session
    }
}
private struct VoiceActivityPort: VoiceActivityCapability {
    let scope: ModelScope
    var availability: CapabilityAvailability {
        get async {
            do {
                return try await scope.perform("speech", "vad.availability") {
                    try await $0.availability(.voiceActivity)
                }
            } catch { return .unavailable(reason: String(describing: error)) }
        }
    }
    func detectVoiceActivity(format: AudioFormat) async throws -> any VoiceActivitySession {
        let session = try await scope.perform("speech", "vad") {
            try await (try await $0.get(.voiceActivity, load: false)).detectVoiceActivity(format: format)
        }
        return ActivitySession(session: session, scope: scope, generation: try scope.admission.check())
    }
}
private struct ActivitySession: VoiceActivitySession {
    let session: any VoiceActivitySession
    let scope: ModelScope
    let generation: UInt64
    func process(_ frame: AudioFrame) async throws -> [VoiceActivityScore] {
        try scope.admission.validate(generation)
        let result = try await scope.perform("speech", "vad.process") { _ in try await session.process(frame) }
        try scope.admission.validate(generation)
        return result
    }
    func finish() async throws -> [VoiceActivityScore] {
        do {
            let result = try await session.finish()
            try scope.admission.validate(generation)
            return result
        } catch {
            scope.report("speech", "vad.finish", error)
            throw error
        }
    }
    func reset() async throws {
        try scope.admission.validate(generation)
        try await scope.perform("speech", "vad.reset") { _ in try await session.reset() }
    }
    func cancel() async { await session.cancel() }
}
public final class ModelVisionContainer: ModelVisionProviding, Sendable {
    private let scope: ModelScope
    fileprivate init(scope: ModelScope) { self.scope = scope }
    public var availability: CapabilityAvailability {
        get async {
            do { return try await scope.perform("vision", "availability") { try await $0.availability(.pose) } } catch {
                return .unavailable(reason: String(describing: error))
            }
        }
    }
    public func load() async throws { try await scope.perform("vision", "load") { try await $0.load(.pose) } }
    public func warmup() async throws { try await warmup(reportLoading: { _ in }) }
    public func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) async throws {
        try await scope.perform("vision", "warmup") { try await $0.warmup(.pose, reportLoading: reportLoading) }
    }
    public func unload() async throws {
        try await scope.perform("vision", "unload", inference: false) { try await $0.unload(.pose) }
    }
    public func status() async throws -> ModelState {
        try await scope.perform("vision", "status", inference: false) { try await $0.status(.pose) }
    }
    public func estimatePose(_ request: PoseRequest) async throws -> PoseResult {
        try await scope.perform("vision", "pose") {
            try await (try await $0.get(.pose, load: false)).estimatePose(request)
        }
    }
}
public final class ModelArtifactsContainer: ModelArtifactsManaging, Sendable {
    private let scope: ModelScope
    fileprivate init(scope: ModelScope) { self.scope = scope }
    public func prepare() async throws { try await scope.perform("artifacts", "prepare", inference: false) { _ in } }
    public func artifactSnapshots() async throws -> [ModelArtifactSnapshot] {
        try await scope.perform("artifacts", "snapshot", inference: false) { try await $0.artifactSnapshots() }
    }
    public func downloadArtifact(_ id: String, source: ModelDownloadSource) async throws {
        try await scope.perform("artifacts", "download", inference: false) {
            try await $0.downloadArtifact(id, source: source)
        }
    }
    public func cancelArtifact(_ id: String) async throws {
        try await scope.perform("artifacts", "cancel", inference: false) { try await $0.cancelArtifact(id) }
    }
    public func removeArtifact(_ id: String, quiesce: @escaping @Sendable () async -> Void) async throws {
        try await scope.perform("artifacts", "remove", inference: false) {
            try await $0.removeArtifact(id, quiesce: quiesce)
        }
    }
}

/// Default provider registration is instance-local; no process cache or mutable static selection.
enum DefaultModelAssembly {
    static let mossNano = ModelID("moss-tts-nano")
    @available(iOS 27, macOS 27, *)
    static func assemble(resources: URL, selection: SpeechSelection, admission: InferenceAdmission) async throws
        -> ModelManager
    {
        let manager = try ModelManager(admission: admission)
        do {
            try await registerSpeechModels(manager: manager, resources: resources)
            try await manager.register(chatRegistration(resources: resources, configuration: nil), defaults: [.chat])
            try await registerSpeechDefaults(manager: manager, selection: selection)
            try await registerVision(manager: manager, resources: resources)
            return manager
        } catch {
            await manager.shutdown()
            throw error
        }
    }
}
