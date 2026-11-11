import Foundation
import StorageCache
import StorageFiles

#if os(iOS)

    import StorageDevices
    import FunctionContracts
    import AgentCore
    import Gateway

    import ModelKit
    import ModelKitDefaults
    import ModelKitHub
    import ModelKitRuntime
    import Observation
    import PlatformKit
    import StorageCore
    import StorageChat
    import StorageMedia
    import StorageTasks
    import UI

    /// Instance-local module root. Only explicit lifecycle operations create runtime work.
    @MainActor @Observable
    @available(iOS 27, *)
    public final class AgentContainer {
        @ObservationIgnored private let containerFailures: ContainerFailureChannel
        @ObservationIgnored private let repositories: @Sendable () throws -> AgentRepositories
        @ObservationIgnored private let audio: AudioContainer
        @ObservationIgnored private let cameraDevice: any CameraCapturing
        private let albumUI: UIAlbumContainer
        public let island: IslandState
        public let windows: WindowState
        private let cameraUI: UICameraContainer
        @ObservationIgnored private let languageModels: any ModelLanguageProviding
        @ObservationIgnored private let speechModels: any ModelSpeechProviding
        @ObservationIgnored private let visionModels: any ModelVisionProviding
        @ObservationIgnored private let modelArtifacts: any ModelArtifactsManaging
        @ObservationIgnored private let memoryPressure: @Sendable () async -> Void
        private func makeStateContext() throws -> AgentStateContext {
            let context = AgentStateContext()
            try AssistantStateBindings.register(in: context) { [weak self] path in
                guard let self else { throw ContainerContextError.closed }
                return try await self.readState(path)
            }
            return context
        }
        /// Complete, unfiltered inspection read. Each consumer owns its selection policy.
        @ObservationIgnored public var readState: @Sendable (String) async throws -> any Encodable & Sendable = { _ in
            throw ContainerContextError.missing
        }
        public func stateSnapshot() async throws -> AgentStateSnapshot {
            try Task.checkCancellation()
            return AgentStateSnapshot(
                path: "agents",
                runtime: [
                    "available": .flag(lifecycle.isAvailable), "stopped": .flag(lifecycle.isStopped),
                    "foregroundRequested": .flag(lifecycle.isForegroundRequested),
                ], health: lifecycle.healthFailure == nil ? .unknown : .fault,
                issues: lifecycle.healthFailure.map {
                    [.init(code: $0.code.rawValue, impact: "agentExecutionUnavailable")]
                } ?? [],
                children: [
                    .init(path: "agents.assistant"), .init(path: "agents.applicationcontrol"),
                    .init(path: "agents.writer"), .init(path: "agents.memory"), .init(path: "agents.photographer"),
                    .init(path: "agents.speechperception"),
                    .init(path: "agents.visionperception"),
                ])
        }
        public func stateReaders() async throws -> [String: AgentStateSnapshot.Reader] {
            [
                "agents": AgentStateSnapshot.reader(of: self) { try await $0.stateSnapshot() },
                "agents.assistant": AgentStateSnapshot.reader(of: assistant) { try await $0.stateSnapshot() },
                "agents.applicationcontrol": AgentStateSnapshot.reader(of: applicationControl) {
                    try await $0.stateSnapshot()
                },
                "agents.writer": AgentStateSnapshot.reader(of: writer) { try await $0.stateSnapshot() },
                "agents.memory": AgentStateSnapshot.reader(of: memory) { try await $0.stateSnapshot() },
                "agents.photographer": AgentStateSnapshot.reader(of: photographer) { try await $0.stateSnapshot() },
                "agents.speechperception": AgentStateSnapshot.reader(of: speechPerception) {
                    try await $0.stateSnapshot()
                },
                "agents.visionperception": AgentStateSnapshot.reader(of: visionPerception) {
                    try await $0.stateSnapshot()
                },
            ]
        }
        public var onModelConfigurationChanged: (@MainActor () -> Void)?
        private let homeUI: UIHomeContainer
        private let settingsUI: UISettingsContainer
        private let resourcesUI: UIModelResourcesContainer
        private let navigationUI: UINavigationContainer
        private let historyUI: UIHistoryContainer
        private let devicesUI: UIDeviceSettingsContainer
        private let diagnosticsUI: UIDiagnosticsContainer
        private let cacheStorage: CacheContainer
        private let filesStorage: FilesContainer
        let bluetooth: any AgentDeviceAccess
        let camera: any AgentCameraAccess
        public init(
            containerFailures: ContainerFailureChannel,
            home: UIHomeContainer, settings: UISettingsContainer, modelResources: UIModelResourcesContainer,
            navigation: UINavigationContainer, history: UIHistoryContainer, devices: UIDeviceSettingsContainer,
            diagnostics: UIDiagnosticsContainer,
            repositories: @escaping @Sendable () throws -> AgentRepositories,
            cache: CacheContainer, files: FilesContainer,
            camera: any CameraCapturing, cameraPresentation: any CameraPresenting,
            cameraUI: UICameraContainer, albumUI: UIAlbumContainer, windows: WindowState, island: IslandState,
            cameraAccess: any AgentCameraAccess, deviceAccess: any AgentDeviceAccess, facades: AgentUIFacades,
            audio: AudioContainer,
            languageModels: any ModelLanguageProviding, speechModels: any ModelSpeechProviding,
            visionModels: any ModelVisionProviding, modelArtifacts: any ModelArtifactsManaging,
            memoryPressure: @escaping @Sendable () async -> Void
        ) {
            self.containerFailures = containerFailures
            assistant = AssistantContainer(home: home)
            speechPerception = SpeechPerceptionContainer(home: home, diagnostics: diagnostics)
            applicationControl = ApplicationControlContainer(
                settings: settings, resources: modelResources, diagnostics: diagnostics,
                devices: devices, navigation: navigation, facades: facades, failures: containerFailures)
            memory = MemoryContainer(history: history, facades: facades)
            photographer = PhotographerContainer(camera: cameraUI, facades: facades)
            homeUI = home
            settingsUI = settings
            resourcesUI = modelResources
            navigationUI = navigation
            historyUI = history
            devicesUI = devices
            diagnosticsUI = diagnostics
            self.audio = audio
            self.cacheStorage = cache
            self.filesStorage = files
            self.repositories = repositories
            cameraDevice = camera
            self.albumUI = albumUI
            self.cameraUI = cameraUI
            self.windows = windows
            self.island = island
            self.camera = cameraAccess
            self.bluetooth = deviceAccess
            self.languageModels = languageModels
            self.speechModels = speechModels
            self.visionModels = visionModels
            self.modelArtifacts = modelArtifacts
            self.memoryPressure = memoryPressure
        }
        public let assistant: AssistantContainer
        public let applicationControl: ApplicationControlContainer
        public let writer = WriterContainer()
        public let memory: MemoryContainer
        public let photographer: PhotographerContainer
        public let speechPerception: SpeechPerceptionContainer
        public let visionPerception = VisionPerceptionContainer()
        @ObservationIgnored private lazy var lifecycle = AgentContainerLifecycle(
            start: { [unowned self] in try await self.startServices() },
            invalidate: { [unowned self] in self.invalidateServices() },
            foreground: { [unowned self] in try await self.applyForeground($0) },
            stop: { [unowned self] in try await self.stopServices() },
            report: { [containerFailures] failure in
                containerFailures.report(
                    module: "agents", component: failure.component, operation: failure.operation,
                    error: failure, details: .init(code: failure.code.rawValue, isCancellation: failure.isCancellation))
            })
        public var isAvailable: Bool { lifecycle.isAvailable }
        public func start() async throws(AgentFailure) { try await lifecycle.start() }
        public func invalidate() { lifecycle.invalidate() }
        public func setForeground(_ value: Bool) async throws(AgentFailure) { try await lifecycle.setForeground(value) }
        public func setSceneActive(_ value: Bool) async throws {
            if value { try await lifecycle.setForeground(true) }
            foreground = value
            await writer.setSceneActive(value)
            guard !isolatedPresentation else { return }
            reportEnvironment(.scene, value: value ? "active" : "background")
            if !value {
                visionPerception.invalidate()
                try await visionPerception.suspend()
            }
        }

        public func stop() async throws(AgentFailure) { try await lifecycle.stop() }
        @ObservationIgnored private var runtimeValue: AgentRuntime?
        public func reportModelPreparation(loading: Bool) {
            reportEnvironment(.modelPreparation, value: loading ? "loading" : "idle")
        }
        public func reportEnvironment(_ category: AppEnvironmentFact.Category, value: String) {
            guard isAvailable else { return }
            applicationControl.reportEnvironment(category, value: value)
        }
        private func artifactManager() async throws -> any ModelArtifactsManaging {
            try await modelArtifacts.prepare()
            return modelArtifacts
        }

        public var album: UIAlbumContainer { albumUI }
        public var navigation: NavigationState { navigationUI.state }

        public func navigate(_ destination: AppDestination?) {
            navigationUI.presentation.show(destination)
        }
        /// App binds the native presentation endpoint before starting this cognitive receive loop.
        public func connectVision(
            sessionID: String, mirrored: Bool,
            status: @escaping @MainActor @Sendable (String?, String) -> Void
        ) async throws {
            do {
                try lifecycle.requireAvailable()
                try await visionPerception.run(
                    runtime: runtime(), pose: visionModels, camera: cameraDevice,
                    sessionID: sessionID, mirrored: mirrored, status: status)
            } catch is CancellationError { throw CancellationError() } catch {
                containerFailures.report(
                    module: "agents", component: "visionPerception", operation: "session", error: error)
                throw error
            }
        }

        private func makeHistoryChat() async throws -> any ChatCapability {
            try await applicationControl.settingsControls.restore()
            await speechPerception.beginSettingsChange()
            defer { speechPerception.endSettingsChange() }
            try Task.checkCancellation()
            return languageModels
        }
        private func quiesceForModelRemoval(_ id: String) async {
            if id == "d3-edge" {
                await inputDecisionService?.quiesceLocal()
            } else if id == "yolo26n-pose" {
                await camera.pauseVisionForModelMaintenance()
            } else {
                await speechPerception.beginSettingsChange()
                speechPerception.endSettingsChange()
            }
        }
        @ObservationIgnored private var inputDecisionService: AssistantInputDecision?
        private var executionPreparationStarted = false
        /// Called by App's executionBindings node after foundational repositories are ready.
        public func prepareExecutionBindings(
            declarations: [ActionDeclaration]
        ) throws -> AgentExecutionPreparation {
            guard !lifecycle.isStopped else { throw AgentContainerError.stopped }
            guard !executionPreparationStarted else { throw GatewayContainerError.alreadyConfigured }
            executionPreparationStarted = true
            try Task.checkCancellation()
            _ = try repositories()
            try AgentConfigurations.installDeclarations(declarations)
            let maintenance = AgentMaintenancePorts(
                artifacts: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.artifactManager()
                },
                quiesce: { [weak self] id in await self?.quiesceForModelRemoval(id) },
                bindSpeech: { [weak self] recognition, synthesis in
                    guard let self else { throw CancellationError() }
                    await self.speechPerception.beginSettingsChange()
                    defer {
                        self.speechPerception.endSettingsChange()
                        self.onModelConfigurationChanged?()
                    }
                    try await self.speechModels.configure(recognition: recognition, synthesis: synthesis)
                },
                beginSettings: { [weak self] in await self?.speechPerception.beginSettingsChange() },
                endSettings: { [weak self] in
                    self?.speechPerception.endSettingsChange()
                    self?.onModelConfigurationChanged?()
                },
                resourcesPresented: { [weak self] in
                    self?.applicationControl.acceptResourceSnapshot()
                    if let service = self?.inputDecisionService { Task { await service.resetLocalFailure() } }
                })
            let makeDecision: @MainActor (AgentBusinessBindings) -> AssistantInputDecision = { business in
                let configuration = business.decisionConfiguration
                let reportDecision = business.decisionStatus
                let service = AssistantInputDecision(
                    local: self.languageModels.decision,
                    configuration: {
                        guard let configuration else { return (false, nil) }
                        let (useLocal, cloud) = try await configuration()
                        guard let cloud else { return (useLocal, nil) }
                        return (useLocal, { try await cloud().capability })
                    },
                    report: { value in await reportDecision(value) })
                self.inputDecisionService = service
                return service
            }
            return try AgentRuntime.prepare(
                makeInputDecision: makeDecision,
                maintenance: maintenance,
                containerFailures: containerFailures, home: homeUI,
                assistantContainer: assistant, applicationControlContainer: applicationControl,
                memoryContainer: memory, photographerContainer: photographer, writerContainer: writer,
                stateContext: try makeStateContext(), cache: cacheStorage,
                repositories: try repositories(),
                cameraUI: cameraUI, albumUI: albumUI, windowsUI: windows, settingsUI: settingsUI,
                resourcesUI: resourcesUI, devicesUI: devicesUI, historyUI: historyUI, diagnosticsUI: diagnosticsUI,
                cameraControl: camera,
                resourceChanges: { [modelArtifacts] in try await modelArtifacts.observeArtifactChanges() },
                summarizeTitle: { [weak self] conversation in
                    guard let self else { throw CancellationError() }
                    let chat = try await self.makeHistoryChat()
                    try Task.checkCancellation()
                    let records = try self.repositories().assistantConversations
                    let logs = try self.repositories().logs
                    return try await ConversationTitleGenerator.summarize(
                        conversation, using: chat,
                        journal: { request in
                            try await records.saveAuxiliaryRequest(dialog: conversation.id, request: request)
                        },
                        transport: { id, update in
                            try await logs.writeRequestPayload(
                                id, agent: "assistant", json: "", response: "", initial: false, update: update)
                        })
                },
                modelName: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return await self.applicationControl.modelName
                },
                chatProvider: { [languageModels] in languageModels })
        }
        public func bindExecution(_ binding: AgentExecutionBinding, facilities: AgentGatewayCapabilities) throws {
            guard !lifecycle.isStopped else { throw AgentContainerError.stopped }
            guard runtimeValue == nil else { throw GatewayContainerError.alreadyConfigured }
            runtimeValue = try binding.finish(facilities)
        }
        /// App calls this after Gateway stops, retaining execution endpoints through cleanup.
        public func releaseExecutionBindings() async {
            await runtimeValue?.shutdown()
            runtimeValue = nil
        }
        private func runtime() throws -> AgentRuntime {
            guard !lifecycle.isStopped else { throw AgentContainerError.stopped }
            guard let runtimeValue else { throw AgentContainerError.unavailable }
            return runtimeValue
        }
        @ObservationIgnored private var preparation: Task<Void, Error>?
        private var foreground = true
        public var foregroundModelRequirements: [ModelPreparationRequirement] {
            var requirements: [ModelPreparationRequirement] = [.language, .recognition, .synthesis, .voiceActivity]
            if cameraUI.state.perceptionEnabled { requirements.append(.vision) }
            return requirements
        }
        public var isolatedPresentation: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return [
                "-gemma4-validation",
                "-moss-benchmark",
            ].contains { arguments.contains($0) }
        }
        private func prepare(progress: @MainActor (String) -> Void) async throws {
            if let preparation { return try await preparation.value }
            if speechPerception.isReady { return }
            // Progress is a value update; no page lifetime owns the preparation task.
            let task = Task { try await self.prepareServices(progress: { _ in }) }
            preparation = task
            do {
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                progress("本地模型可在设置中下载")
            } catch {
                preparation = nil
                throw error
            }
        }
        private func startAgents() async throws {
            guard !isolatedPresentation else { return }
            let runtime = try runtime()
            try await runtime.output.bindCommunications(try repositories().agentMessages)
            try await applicationControl.start()
            try await photographer.start()
            try await memory.start()
            try await writer.start()
            try await assistant.start()
            runtime.connectFailures()
        }
        private func startNativeServices() async throws {
            guard !isolatedPresentation else { return }
            try await prepare(progress: { _ in })
            try await speechPerception.startInteraction()
            applyNativeForeground(foreground)
        }
        private func invalidateNative() {
            foreground = false
            speechPerception.invalidate()
        }
        private func applyNativeForeground(_ value: Bool) {
            foreground = value
            guard !isolatedPresentation else { return }
            reportEnvironment(.scene, value: value ? "active" : "background")
            if !value { invalidateNative() }
        }
        private func stopNativeServices() async throws {
            invalidateNative()
            preparation?.cancel()
            _ = await preparation?.result
            var cleanupErrors: [any Error] = []
            do { try await speechPerception.stop() } catch { cleanupErrors.append(error) }
            do { try await visionPerception.stop() } catch { cleanupErrors.append(error) }
            if !cleanupErrors.isEmpty { throw NativeCleanupFailure(errors: cleanupErrors) }
        }
        private func stopAgents() async throws {
            var errors: [any Error] = []
            do { try await assistant.stop() } catch { errors.append(error) }
            do { try await photographer.stop() } catch { errors.append(error) }
            do { try await writer.stop() } catch { errors.append(error) }
            do { try await memory.stop() } catch { errors.append(error) }
            do { try await applicationControl.stop() } catch { errors.append(error) }
            if let primary = errors.first {
                throw AgentFailure(
                    component: "roles", operation: "stop", underlying: primary,
                    cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
            }
        }
        private func startServices() async throws {
            try await startAgents()
            try Task.checkCancellation()
            try await startNativeServices()
        }
        private func setInputAvailable(_ value: Bool) {
            assistant.setInputAvailable(value)
            applicationControl.setInputAvailable(value)
            memory.setInputAvailable(value)
            photographer.setInputAvailable(value)
            speechPerception.setInputAvailable(value)
        }
        private func invalidateServices() {
            preparation?.cancel()
            setInputAvailable(false)
            invalidateNative()
            visionPerception.invalidate()
        }
        private func applyForeground(_ value: Bool) async throws {
            if !value {
                var errors: [any Error] = []
                await speechPerception.suspend()
                do { try await visionPerception.suspend() } catch { errors.append(error) }
                do { try await applicationControl.setForeground(false) } catch { errors.append(error) }
                do { try await photographer.setForeground(false) } catch { errors.append(error) }
                do { try await writer.setForeground(false) } catch { errors.append(error) }
                do { try await memory.setForeground(false) } catch { errors.append(error) }
                do { try await assistant.setForeground(false) } catch { errors.append(error) }
                if let primary = errors.first {
                    throw AgentFailure(
                        component: "root", operation: "suspend", underlying: primary,
                        cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
                }
                return
            }
            try await applicationControl.setForeground(true)
            try await photographer.setForeground(true)
            try await memory.setForeground(true)
            try await writer.setForeground(true)
            try await assistant.setForeground(true)
            guard lifecycle.isForegroundRequested else { return }
            applyNativeForeground(true)
            setInputAvailable(true)
        }
        private func stopServices() async throws {
            var errors: [any Error] = []
            do { try await stopNativeServices() } catch { errors.append(error) }
            do { try await stopAgents() } catch { errors.append(error) }
            if let primary = errors.first {
                throw AgentFailure(
                    component: "root", operation: "stop", underlying: primary, cleanupErrors: Array(errors.dropFirst()),
                    code: .cleanupFailed)
            }
        }
        private func prepareServices(progress: @MainActor (String) -> Void) async throws {
            _ = try repositories()
            guard !speechPerception.isReady else { return }
            _ = try await artifactManager()
            _ = try await applicationControl.modelResourcesWorkflow.restoreSource()
            try await applicationControl.settingsControls.restore()
            let prepared = try await VoiceInteractionSession(
                home: homeUI, diagnostics: diagnosticsUI, language: languageModels, speech: speechModels,
                memoryPressure: memoryPressure, audio: audio, runtime: runtime(),
                perceptionContainer: speechPerception,
                modelName: { [applicationControl] in await applicationControl.modelName },
                progress: progress)
            try Task.checkCancellation()
            try speechPerception.installInteraction(prepared)
        }
    }

#endif

/// Module-local, explicitly projected facts. This type never inspects private storage.
public struct AgentStateSnapshot: Codable, Sendable {
    public struct Reference: Codable, Sendable, Hashable {
        public let path: String
        public init(path: String) { self.path = path }
    }
    public enum ReadError: Error, Sendable { case ownerReleased }
    public typealias Reader = @Sendable () async throws -> AgentStateSnapshot
    /// Runtime capability only. Serialization carries Reference indices, never owner objects.
    public static func reader<Owner: AnyObject & Sendable>(
        of owner: Owner, read: @escaping @Sendable (Owner) async throws -> AgentStateSnapshot
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
