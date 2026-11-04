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
    func chatModel(configuration: OpenAIChatConfiguration?) async throws -> ChatModel
}
extension ModelLanguageProviding {
    public func chatModel(configuration: OpenAIChatConfiguration?) async throws -> ChatModel {
        throw CapabilityError.unavailable("Configured chat is not supported by this host")
    }
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
    func observeArtifactChanges() async throws -> AsyncStream<UInt64>
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
    private var rootFailure: ModelFailure?
    private var started = false
    private var stopped = false
    private var cleanupJoined = false
    private var suspension: Task<Void, Never>?
    private var shutdown: Task<Void, Error>?
    public init(
        resources: URL,
        prepareArtifacts: (@Sendable () async throws -> ModelArtifactConfiguration)? = nil,
        onFailure: @escaping @Sendable (String, String, any Error) -> Void = { _, _, _ in },
        maximumPendingLocalChats: Int = 8
    ) {
        let admission = InferenceAdmission(open: false)
        let scope = ModelScope(
            resources: resources, admission: admission, prepareArtifacts: prepareArtifacts, onFailure: onFailure,
            maximumPendingLocalChats: maximumPendingLocalChats)
        self.admission = admission
        self.scope = scope
        language = ModelLanguageContainer(scope: scope)
        speech = ModelSpeechContainer(scope: scope)
        vision = ModelVisionContainer(scope: scope)
        artifacts = ModelArtifactsContainer(scope: scope)
    }
    public func stateSnapshot() async throws -> ModelStateSnapshot {
        try Task.checkCancellation()
        return ModelStateSnapshot(
            path: "model",
            runtime: ["started": .flag(started), "stopped": .flag(stopped), "cleanupJoined": .flag(cleanupJoined)],
            health: rootFailure == nil ? .unknown : .fault,
            issues: rootFailure.map { [.init(code: $0.code.rawValue, impact: "modelCapabilityUnavailable")] } ?? [],
            children: ["model.language", "model.speech", "model.vision", "model.artifacts"].map { .init(path: $0) })
    }
    public func stateReaders() async throws -> [String: ModelStateSnapshot.Reader] {
        var readers: [String: ModelStateSnapshot.Reader] = [
            "model": ModelStateSnapshot.reader(of: self) { try await $0.stateSnapshot() },
            "model.language": ModelStateSnapshot.reader(of: language) { try await $0.stateSnapshot() },
            "model.speech": ModelStateSnapshot.reader(of: speech) { try await $0.stateSnapshot() },
            "model.vision": ModelStateSnapshot.reader(of: vision) { try await $0.stateSnapshot() },
            "model.artifacts": ModelStateSnapshot.reader(of: artifacts) { try await $0.stateSnapshot() },
        ]
        for (component, capabilities) in [
            ("language", [ProvidedCapability.chat]), ("speech", [.recognition, .synthesis, .voiceActivity]),
            ("vision", [.pose]),
        ] {
            readers.merge(try await scope.resourceStateReaders(component, capabilities: capabilities)) { _, new in new }
        }
        return readers
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
            let failure = scope.report("root", "start", error)
            if failure.code == .cleanupFailed || failure.code == .executionFailed { rootFailure = failure }
            throw failure
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
            let failure = scope.report("root", "setForeground", error)
            if failure.code == .cleanupFailed || failure.code == .executionFailed { rootFailure = failure }
            throw failure
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
            cleanupJoined = true
        } catch {
            let failure = scope.report("root", "stop", error)
            if failure.code == .cleanupFailed || failure.code == .executionFailed { rootFailure = failure }
            throw failure
        }
    }
}

private actor ModelScope {
    let resources: URL
    let admission: InferenceAdmission
    let selection = SpeechSelection()
    let failure: @Sendable (String, String, any Error) -> Void
    private let prepareArtifacts: (@Sendable () async throws -> ModelArtifactConfiguration)?
    private var preparedManager: ModelManager?
    private var assembly: Task<ModelManager, Error>?
    private var closed = false
    private var waiters = 0
    private var updating = false
    private var cloudChat: OpenAIChatConfiguration?
    private struct CloudBinding {
        let configuration: OpenAIChatConfiguration
        let id: ModelID
        let capability: Task<any ChatCapability, Error>
    }
    private var cloudBindings: [CloudBinding] = []
    private var localChat: SerialChat?
    private let maximumPendingLocalChats: Int
    init(
        resources: URL, admission: InferenceAdmission,
        prepareArtifacts: (@Sendable () async throws -> ModelArtifactConfiguration)?,
        onFailure: @escaping @Sendable (String, String, any Error) -> Void, maximumPendingLocalChats: Int
    ) {
        self.resources = resources
        self.admission = admission
        self.prepareArtifacts = prepareArtifacts
        failure = onFailure
        self.maximumPendingLocalChats = maximumPendingLocalChats
    }
    func stateSnapshot(_ component: String, capabilities: [ProvidedCapability]) async throws -> ModelStateSnapshot {
        try Task.checkCancellation()
        var runtime: [String: ModelStateSnapshot.Value] = [:]
        let ids = await preparedManager?.resourceIDs(capabilities: Set(capabilities)) ?? []
        let children = ids.map { ModelStateSnapshot.Reference(path: "model." + component + "." + $0) }
        if component == "speech" {
            let preferences = await selection.stateSnapshot()
            runtime["preferCustomRecognition"] = .flag(preferences.recognition)
            runtime["preferCustomSynthesis"] = .flag(preferences.synthesis)
        }
        if component == "artifacts", let value = await preparedManager?.artifactStateSnapshot() {
            runtime.merge([
                "restored": .flag(value.restored), "queued": .count(value.queued), "transfers": .count(value.transfers),
                "deleting": .count(value.deleting), "failures": .count(value.failures), "closed": .flag(value.closed),
            ]) { _, new in new }
        }
        try Task.checkCancellation()
        return ModelStateSnapshot(
            path: "model." + component,
            runtime: runtime.merging([
                "assembled": .flag(preparedManager != nil), "closed": .flag(closed),
                "preparationWaiters": .count(waiters), "updating": .flag(updating),
            ]) { _, new in new },
            children: children)
    }
    func resourceStateReaders(_ component: String, capabilities: [ProvidedCapability]) async throws -> [String:
        ModelStateSnapshot.Reader]
    {
        guard let manager = preparedManager else { return [:] }
        let ids = await manager.resourceIDs(capabilities: Set(capabilities))
        return Dictionary(
            uniqueKeysWithValues: ids.map { id in
                let path = "model." + component + "." + id
                return (
                    path,
                    ModelStateSnapshot.reader(of: manager) { owner in
                        let value = try await owner.resourceStateSnapshot(id)
                        return .init(
                            path: path,
                            runtime: ["phase": .text(value.phase), "inferenceActive": .flag(value.inferenceActive)],
                            stateValues: ["runtime.phase": ModelState.allCases.map(\.rawValue)])
                    }
                )
            })
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
        preparedManager = manager
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
    func chatModel(configuration: OpenAIChatConfiguration?) throws -> ChatModel {
        try admission.checkAlive()
        guard !closed else { throw InferenceAdmissionError.stopped }
        return ChatModel(
            capability: ConfiguredChat(scope: self, configuration: configuration), modelName: configuration?.model)
    }
    private func cloud(_ configuration: OpenAIChatConfiguration) async throws -> any ChatCapability {
        if let binding = cloudBindings.first(where: { $0.configuration == configuration }) {
            return try await binding.capability.value
        }
        let id = ModelID("cloud-chat-" + UUID().uuidString)
        let task = Task<any ChatCapability, Error> { [resources] in
            try await self.perform("language", "configureCloud", inference: false) { manager in
                guard #available(iOS 27, macOS 27, *) else {
                    throw CapabilityError.unavailable("Cloud chat requires OS 27")
                }
                try await manager.register(
                    DefaultModelAssembly.chatRegistration(resources: resources, configuration: configuration, id: id))
                return try await manager.get(id, as: .chat, load: false)
            }
        }
        cloudBindings.append(CloudBinding(configuration: configuration, id: id, capability: task))
        do { return try await task.value } catch {
            cloudBindings.removeAll { $0.id == id }
            throw error
        }
    }
    func selectedChatID() async throws -> ModelID {
        guard let configuration = cloudChat else { return ModelID("chat") }
        _ = try await cloud(configuration)
        guard let id = cloudBindings.first(where: { $0.configuration == configuration })?.id else {
            throw CapabilityError.sessionClosed
        }
        return id
    }
    func selectedChat() async throws -> any ChatCapability {
        if let cloudChat { return try await cloud(cloudChat) }
        return try await perform("language", "localChat") { try await $0.get(.chat, load: false) }
    }
    func chat(_ request: ChatRequest, configuration: OpenAIChatConfiguration?) async throws -> InferenceSession<
        ChatEvent
    > {
        let generation = try admission.check()
        if let configuration {
            let capability = try await cloud(configuration)
            try admission.validate(generation)
            return try await capability.chat(request)
        }
        if localChat == nil {
            localChat = try SerialChat(maximumPending: maximumPendingLocalChats) { [weak self] in
                guard let self else { throw CapabilityError.sessionClosed }
                return try await self.perform("language", "localChat") { try await $0.get(.chat, load: false) }
            }
        }
        guard let localChat else { throw CapabilityError.sessionClosed }
        return try await localChat.chat(request)
    }
    func defaultChat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        try await chat(request, configuration: cloudChat)
    }
    func configureChat(_ configuration: OpenAIChatConfiguration?) async throws {
        guard !updating else { throw CapabilityError.inputBusy }
        updating = true
        defer { updating = false }
        try admission.checkAlive()
        guard !closed else { throw InferenceAdmissionError.stopped }
        if let configuration { _ = try await cloud(configuration) }
        cloudChat = configuration
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
        await localChat?.cancelAll()
        if let assembly, let manager = try? await assembly.value { await manager.suspend() }
    }
    func memoryPressure() async {
        if !closed, let assembly, let manager = try? await assembly.value { _ = await manager.handleMemoryPressure() }
    }
    func stop() async throws {
        closed = true
        await localChat?.cancelAll()
        for binding in cloudBindings { binding.capability.cancel() }
        for binding in cloudBindings { _ = await binding.capability.result }
        cloudBindings.removeAll()
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

private struct ConfiguredChat: ChatCapability {
    let scope: ModelScope
    let configuration: OpenAIChatConfiguration?
    var availability: CapabilityAvailability { .available }
    var supportsToolCalls: Bool { configuration != nil }
    var supportsImages: Bool { configuration != nil }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        try await scope.chat(request, configuration: configuration)
    }
}

public final class ModelLanguageContainer: ModelLanguageProviding, Sendable {
    public func stateSnapshot() async throws -> ModelStateSnapshot {
        try Task.checkCancellation()
        return try await scope.stateSnapshot("language", capabilities: [.chat])
    }

    private let scope: ModelScope
    fileprivate init(scope: ModelScope) { self.scope = scope }
    public var availability: CapabilityAvailability {
        get async {
            do { return await (try await scope.selectedChat()).availability } catch {
                return .unavailable(reason: String(describing: error))
            }
        }
    }
    public var supportsToolCalls: Bool { get async { (try? await scope.selectedChat().supportsToolCalls) ?? false } }
    public var supportsImages: Bool { get async { (try? await scope.selectedChat().supportsImages) ?? false } }
    public func chatModel(configuration: OpenAIChatConfiguration?) async throws -> ChatModel {
        try await scope.chatModel(configuration: configuration)
    }
    public func chat(_ request: ChatRequest, using configuration: OpenAIChatConfiguration?) async throws
        -> InferenceSession<ChatEvent>
    {
        try await scope.chat(request, configuration: configuration)
    }
    public func configure(_ configuration: OpenAIChatConfiguration?) async throws {
        try await scope.configureChat(configuration)
    }
    public func warmup() async throws { try await warmup(reportLoading: { _ in }) }
    public func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) async throws {
        let id = try await scope.selectedChatID()
        try await scope.perform("language", "warmup") { try await $0.warmup(id, reportLoading: reportLoading) }
    }
    public func load() async throws {
        let id = try await scope.selectedChatID()
        try await scope.perform("language", "load") { try await $0.load(id) }
    }
    public func unload() async throws {
        let id = try await scope.selectedChatID()
        try await scope.perform("language", "unload", inference: false) { try await $0.unload(id) }
    }
    public func status() async throws -> ModelState {
        let id = try await scope.selectedChatID()
        return try await scope.perform("language", "status", inference: false) { try await $0.status(id) }
    }
    public func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let session = try await scope.defaultChat(request)
        session.observeFailure { [scope] in scope.report("language", "chat.stream", $0) }
        return session
    }
}

public final class ModelSpeechContainer: ModelSpeechProviding, Sendable {
    public func stateSnapshot() async throws -> ModelStateSnapshot {
        try Task.checkCancellation()
        return try await scope.stateSnapshot("speech", capabilities: [.recognition, .synthesis, .voiceActivity])
    }

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
    public func stateSnapshot() async throws -> ModelStateSnapshot {
        try Task.checkCancellation()
        return try await scope.stateSnapshot("vision", capabilities: [.pose])
    }

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
    public func stateSnapshot() async throws -> ModelStateSnapshot {
        try Task.checkCancellation()
        return try await scope.stateSnapshot("artifacts", capabilities: [])
    }

    private let scope: ModelScope
    fileprivate init(scope: ModelScope) { self.scope = scope }
    public func prepare() async throws { try await scope.perform("artifacts", "prepare", inference: false) { _ in } }
    public func observeArtifactChanges() async throws -> AsyncStream<UInt64> {
        try await scope.perform("artifacts", "observe", inference: false) { try await $0.observeArtifactChanges() }
    }
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

/// Module-local, explicitly projected facts. This type never inspects private storage.
public struct ModelStateSnapshot: Codable, Sendable {
    public struct Reference: Codable, Sendable, Hashable {
        public let path: String
        public init(path: String) { self.path = path }
    }
    public enum ReadError: Error, Sendable { case ownerReleased }
    public typealias Reader = @Sendable () async throws -> ModelStateSnapshot
    /// Runtime capability only. Serialization carries Reference indices, never owner objects.
    public static func reader<Owner: AnyObject & Sendable>(
        of owner: Owner, read: @escaping @Sendable (Owner) async throws -> ModelStateSnapshot
    ) -> Reader {
        { [weak owner] in
            try Task.checkCancellation()
            guard let owner else { throw ReadError.ownerReleased }
            return try await read(owner)
        }
    }
    public indirect enum Value: Codable, Sendable, Equatable {
        case text(String)
        case flag(Bool)
        case count(Int)
        case unsigned(UInt64)
        case number(Double)
        case integers([Int])
        case texts([String])
        case object([String: Value])
        case array([Value])
        case unknown
        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .unknown
            } else if let flag = try? value.decode(Bool.self) {
                self = .flag(flag)
            } else if let count = try? value.decode(Int.self) {
                self = .count(count)
            } else if let unsigned = try? value.decode(UInt64.self) {
                self = .unsigned(unsigned)
            } else if let number = try? value.decode(Double.self) {
                self = .number(number)
            } else if let integers = try? value.decode([Int].self) {
                self = .integers(integers)
            } else if let texts = try? value.decode([String].self) {
                self = .texts(texts)
            } else if let object = try? value.decode([String: Value].self) {
                self = .object(object)
            } else if let array = try? value.decode([Value].self) {
                self = .array(array)
            } else {
                self = .text(try value.decode(String.self))
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .text(let item): try value.encode(item)
            case .flag(let item): try value.encode(item)
            case .count(let item): try value.encode(item)
            case .unsigned(let item): try value.encode(item)
            case .number(let item): try value.encode(item)
            case .integers(let item): try value.encode(item)
            case .texts(let item): try value.encode(item)
            case .object(let item): try value.encode(item)
            case .array(let item): try value.encode(item)
            case .unknown: try value.encodeNil()
            }
        }
    }
    public enum Health: String, Codable, Sendable { case healthy, limited, fault, unknown }
    public struct Issue: Codable, Sendable {
        public let code: String
        public let impact: String
        public init(code: String, impact: String) {
            self.code = code
            self.impact = impact
        }
    }
    public struct Descriptor: Codable, Sendable {
        public let path: String
        public let business: [String]
        public let runtime: [String]
        public let children: [Reference]
        public let meanings: [String: String]
        public let units: [String: String]
        public let stateValues: [String: [String]]
    }
    public let path: String
    public let business: [String: Value]
    public let runtime: [String: Value]
    public let health: Health
    public let issues: [Issue]
    public let children: [Reference]
    /// Collection time only; measurement age belongs to the owning business fact.
    public let collectedAt: Date
    public let meanings: [String: String]
    public let units: [String: String]
    public let stateValues: [String: [String]]
    public var stateDescriptor: Descriptor {
        Descriptor(
            path: path, business: business.keys.sorted(), runtime: runtime.keys.sorted(),
            children: children, meanings: meanings, units: units,
            stateValues: stateValues.merging(["health": ["healthy", "limited", "fault", "unknown"]]) { current, _ in
                current
            })
    }
    public init(
        path: String, business: [String: Value] = [:], runtime: [String: Value] = [:],
        health: Health = .unknown, issues: [Issue] = [], children: [Reference] = [],
        meanings: [String: String] = [:], units: [String: String] = [:], stateValues: [String: [String]] = [:]
    ) {
        self.path = path
        self.meanings = meanings
        self.units = units
        self.stateValues = stateValues
        self.business = business
        self.runtime = runtime
        self.health = health
        self.issues = issues
        self.children = children
        collectedAt = Date()
    }
}

public enum ModelPreparationRequirement: String, Sendable {
    case language, recognition, synthesis, voiceActivity, vision
}
@MainActor public struct ModelPreparationStep {
    public let id: String
    public let isReady: @MainActor () async throws -> Bool
    public let prepare: @MainActor (@escaping @Sendable (Bool) async -> Void) async throws -> Void
}
extension ModelContainer {
    @MainActor public func preparationSteps(for requirements: [ModelPreparationRequirement]) -> [ModelPreparationStep] {
        var seen: Set<String> = []
        return requirements.filter { seen.insert($0.rawValue).inserted }.map { requirement in
            let status: @MainActor () async throws -> ModelState
            let warmup: @MainActor (@escaping @Sendable (Bool) async -> Void) async throws -> Void
            switch requirement {
            case .language:
                status = { try await self.language.status() }
                warmup = { try await self.language.warmup(reportLoading: $0) }
            case .vision:
                status = { try await self.vision.status() }
                warmup = { try await self.vision.warmup(reportLoading: $0) }
            case .recognition, .synthesis, .voiceActivity:
                let capability: ProvidedCapability =
                    requirement == .recognition
                    ? .recognition
                    : requirement == .synthesis ? .synthesis : .voiceActivity
                status = { try await self.speech.status(capability) }
                warmup = { try await self.speech.warmup(capability, reportLoading: $0) }
            }
            return ModelPreparationStep(
                id: requirement.rawValue,
                isReady: {
                    let value = try await status()
                    return value == .ready || value == .unmanaged
                }, prepare: warmup)
        }
    }
}
