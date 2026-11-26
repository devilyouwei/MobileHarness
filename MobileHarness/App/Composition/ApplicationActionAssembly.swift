import Actions
import Agents
import AppLifecycle
import Foundation
import FunctionContracts
import Gateway
import ModelKitDefaults
import ModelKitRuntime
import PlatformKit
import Storage
import UI

@MainActor @available(iOS 27, *)
final class ApplicationActionAssembly {
    weak var agents: AgentContainer?
    private let actionSnapshots = AsyncStream<ActionExecutionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var actionLog: Task<Void, Never>?
    weak var homePreparation: ForegroundPreparation?
    private var selectHomeModels:
        (@MainActor () async throws -> (writer: ManagedModelResource?, decision: ManagedModelResource?))?
    private var roleModels: [ModelSettingsChange.Role: ManagedModelResource] = [:]
    private var changing: Set<ModelSettingsChange.Role>?
    private var heldRoles: Set<ModelSettingsChange.Role> = []
    private var changeCleanup: Task<Void, Never>?
    private var languageWorker: Task<Void, Never>?
    private var pendingLanguageChange = false
    private var closed = false
    private let language: @Sendable () -> AppLanguage
    init(language: @escaping @Sendable () -> AppLanguage) {
        self.language = language
    }

    func connectActionLog(to log: any RuntimeLogWriting) -> @Sendable (ActionExecutionSnapshot) -> Void {
        let (stream, continuation) = actionSnapshots
        let language = language
        actionLog = Task {
            for await snapshot in stream {
                log.record(
                    .actions(
                        revision: snapshot.revision,
                        records: snapshot.records.map { ActionActivityItem(execution: $0, language: language()) },
                        evictedCount: snapshot.evictedCount))
            }
        }
        return { snapshot in continuation.yield(snapshot) }
    }

    func stopActionLog() async {
        closed = true
        languageWorker?.cancel()
        await languageWorker?.value
        await changeCleanup?.value
        actionSnapshots.continuation.finish()
        await actionLog?.value
        actionLog = nil
    }
    func dependencies(
        storage: StorageContainer, model: ModelContainer, platform: PlatformContainer,
        ui: UIContainer, language: @escaping @Sendable () -> AppLanguage
    ) -> ActionsDependencies {
        ActionsDependencies(
            files: storage.files, cache: storage.cache, model: model, platform: platform, ui: ui,
            presentationLanguage: language,
            workspaces: { try storage.database.workspaces },
            media: { try storage.database.media }, devices: { try storage.database.devices },
            connectVision: { [weak self] session, mirrored, endpoint in
                guard let agents = self?.agents else { throw ActionsContainerError.unavailable }
                try await agents.connectVision(
                    sessionID: session, mirrored: mirrored,
                    status: { message, session in endpoint.visionStatus(message, sessionID: session) })
            })
    }
    func prepare(_ request: AgentBusinessRequest, actions: ActionsContainer) throws -> AgentBusinessBindings {
        let ports = try actions.configureBusiness(request: request)
        selectHomeModels = ports.homeModelSelections
        return AgentBusinessBindings(
            catalog: ports.catalog, readWebScreenshot: ports.readWebScreenshot,
            artifactStreaming: ports.artifactStreaming,
            writerArtifacts: ports.writerArtifacts,
            writerModel: ports.writerModel, decisionConfiguration: ports.decisionConfiguration,
            decisionStatus: ports.decisionStatus,
            inputQueueStatus: ports.inputQueueStatus, settings: ports.settings,
            discovery: ports.discovery, providerPresentation: ports.providerPresentation,
            resources: ports.resources, connectionFacts: ports.connectionFacts,
            trackingAvailable: ports.trackingAvailable,
            bindTracking: ports.bindTracking,
            bindDeferredFailure: ports.bindDeferredFailure,
            observeTranscript: ports.observeTranscript, output: ports.output,
            speechEnhancementEnabled: ports.speechEnhancementEnabled,
            keywordDetection: ports.keywordDetection, speechDetection: ports.speechDetection,
            decodeResources: ports.decodeResources,
            makeVoice: { host in
                let voice = try ports.makeVoice(
                    ActionsVoiceHost(
                        sessionID: host.sessionID, cancelReply: host.cancelReply,
                        detection: host.detection, adaptFailure: SpeechPlaybackFailure.adapting,
                        preparePlayback: host.preparePlayback, playbackChanged: host.playbackChanged))
                return AgentVoiceExecution(
                    lifecycle: AppVoiceLifecycle(value: voice.lifecycle), spectrum: voice.spectrum,
                    diagnostic: voice.diagnostic, stopDiagnostic: voice.stopDiagnostic,
                    detection: AppDetectionControl(value: voice.detection), validate: voice.validate)
            })
    }

    func homeModels(using model: ModelContainer, vision: Bool) async throws -> [ManagedModelResource] {
        guard let selectHomeModels else { throw ActionsContainerError.unavailable }
        let selection = try await selectHomeModels()
        var models = [try await model.configuredAssistantResource()]
        models += [selection.writer, selection.decision].compactMap { $0 }
        let speechCapabilities: [ProvidedCapability] = [
            .recognition, .synthesis, .voiceActivity, .enhancement, .keywordSpotting, .endpointConfirmation,
        ]
        for capability in speechCapabilities {
            if let selected = try await model.configuredSpeechResource(capability) { models.append(selected) }
        }
        if vision { models.append(try await model.resource("yolo26n-pose")) }
        try Task.checkCancellation()
        roleModels[.writer] = selection.writer
        roleModels[.decision] = selection.decision
        var seen: Set<String> = []
        return models.filter { seen.insert($0.identity.modelID).inserted }
    }

    func beginModelChange(
        _ change: ModelSettingsChange, using model: ModelContainer, forLanguage: Bool = false
    ) async throws {
        guard !closed else { throw CancellationError() }
        guard changing == nil, changeCleanup == nil, forLanguage || languageWorker == nil else {
            throw ActionsContainerError.unavailable
        }
        changing = change.roles
        homePreparation?.beginConfigurationChange()
        do {
            var resources: [String: ManagedModelResource] = [:]
            for id in change.modelIDs {
                let resource =
                    if id == "apple-recognition", !forLanguage {
                        try await model.appleRecognitionResource()
                    } else { try await model.resource(id) }
                resources[resource.identity.modelID] = resource
            }
            for role in change.roles {
                let selected: ManagedModelResource?
                switch role {
                case .assistant: selected = try await model.configuredAssistantResource()
                case .writer, .decision: selected = roleModels[role]
                case .vision: selected = try await model.resource("yolo26n-pose")
                default:
                    if let capability = ProvidedCapability(rawValue: role.rawValue) {
                        selected = try await model.configuredSpeechResource(capability)
                    } else {
                        selected = nil
                    }
                }
                if let selected { resources[selected.identity.modelID] = selected }
            }
            var roles = change.roles
            if let writer = roleModels[.writer], resources[writer.identity.modelID] != nil { roles.insert(.writer) }
            if let decision = roleModels[.decision], resources[decision.identity.modelID] != nil {
                roles.insert(.decision)
            }
            let assistant = try await model.configuredAssistantResource()
            if resources[assistant.identity.modelID] != nil {
                roles.insert(.assistant)
            }
            changing = roles
            let newRoles = roles.subtracting(heldRoles)
            heldRoles.formUnion(roles)
            try await agents?.cancelWorkForModelChange(newRoles)
            for id in resources.keys.sorted() {
                try await resources[id]?.unload(cancelActive: true)
            }
        } catch {
            finishModelChange(using: model)
            throw error
        }
    }

    func finishModelChange(using model: ModelContainer) {
        guard changing != nil else { return }
        changing = nil
        if pendingLanguageChange, !closed, languageWorker == nil {
            startLanguageChange(using: model)
        } else {
            homePreparation?.endConfigurationChange()
        }
    }

    func releaseModelConsumers(using model: ModelContainer) {
        guard changing == nil, changeCleanup == nil, !heldRoles.isEmpty else { return }
        let roles = heldRoles
        heldRoles.removeAll()
        changeCleanup = Task {
            await agents?.endModelChange(roles)
            changeCleanup = nil
            startLanguageChange(using: model)
        }
    }

    func languageChanged(using model: ModelContainer, report: @escaping @MainActor (any Error) -> Void) {
        reportLanguageFailure = report
        pendingLanguageChange = true
        startLanguageChange(using: model)
    }

    private var reportLanguageFailure: (@MainActor (any Error) -> Void)?
    private func startLanguageChange(using model: ModelContainer) {
        guard !closed, pendingLanguageChange, changing == nil, changeCleanup == nil, languageWorker == nil
        else { return }
        pendingLanguageChange = false
        homePreparation?.beginConfigurationChange()
        languageWorker = Task {
            var began = false
            do {
                try await beginModelChange(
                    .init(
                        roles: [.recognition, .synthesis, .assistant, .writer, .decision],
                        modelIDs: ["apple-recognition", "apple-recognition-zh-CN"]), using: model, forLanguage: true)
                began = true
            } catch is CancellationError {
            } catch { reportLanguageFailure?(error) }
            languageWorker = nil
            if began {
                finishModelChange(using: model)
            } else if pendingLanguageChange {
                startLanguageChange(using: model)
            } else if changing == nil {
                homePreparation?.endConfigurationChange()
            }
        }
    }
}
