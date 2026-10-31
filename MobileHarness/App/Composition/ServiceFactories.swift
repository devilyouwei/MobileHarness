import Actions
import Agents
import AppLifecycle
import AppStorage
import Foundation
import Gateway
import ModelKitDefaults
import PlatformKit
import Storage
import StorageCache
import StorageCore
import UI

@MainActor enum ServiceFactories {
    struct Services {
        let registry: ApplicationContainer
        let containerFailures: ContainerFailureChannel
        let uiContainer: UIContainer
        let platform: PlatformContainer
        let storage: StorageContainer
        let model: ModelContainer
        let actions: ActionsContainer
        let gateway: GatewayContainer
        let agents: AgentContainer
        let inspection: ApplicationStateInspection
        let actionAssembly: ApplicationActionAssembly
        let ui: ApplicationPresentation
        let homePreparation: ForegroundPreparation
    }
    static func make() -> Services {
        let root = URL.applicationSupportDirectory.appendingPathComponent("MobileHarness", isDirectory: true)
        let registry = ApplicationContainer(
            root: root, uiConfiguration: .init(settings: SettingsProviderAdapter.initial),
            modelArtifacts: { try ArtifactServices.configuration(files: $0) })
        let containerFailures = registry.containerFailures()
        let storage = registry.storage()
        let files = storage.files
        let uiContainer = registry.ui()
        let presentation = registry.cameraPresentation()
        let platform = registry.platform()
        let camera = platform.vision.camera
        let model = registry.model()
        let gateway = registry.gateway()
        let actionAssembly = ApplicationActionAssembly(gateway: gateway)
        let actionHost = ActionsContainer.makeBusiness(
            dependencies: actionAssembly.dependencies(
                storage: storage, model: model, platform: platform, ui: uiContainer),
            onFailure: { [containerFailures] failure in
                containerFailures.report(
                    module: "actions", component: "container", operation: failure.operation,
                    error: failure, details: .init(code: failure.code.rawValue, isCancellation: failure.isCancellation))
            })
        let actions = actionHost.container
        registry.registerActions(actions)
        let hosts = actionHost.capabilities
        let agents = registry.agents {
            AgentContainer(
                containerFailures: containerFailures,
                home: uiContainer.home, settings: uiContainer.settings, modelResources: uiContainer.modelResources,
                navigation: uiContainer.navigation, history: uiContainer.history, devices: uiContainer.devices,
                diagnostics: uiContainer.diagnostics,
                repositories: {
                    return try AgentRepositories(
                        chat: storage.database.chat, tasks: storage.database.tasks, media: storage.database.media,
                        devices: storage.database.devices)
                }, cache: storage.cache, files: files, camera: camera,
                cameraPresentation: presentation,
                cameraUI: uiContainer.camera, albumUI: uiContainer.album,
                cameraAccess: AppCameraAccess(hosts.camera),
                deviceAccess: AppDeviceAccess(hosts.device),
                facades: hosts.facades,
                audio: platform.audio,
                languageModels: model.language, speechModels: model.speech, visionModels: model.vision,
                modelArtifacts: model.artifacts, memoryPressure: { await model.handleMemoryPressure() })
        }
        let inspection = ApplicationStateInspection()
        // Root paths are compile-time declarations; duplicates indicate a composition defect.
        do {
            try inspection.registerRoot(
                "ui",
                readers: { [weak uiContainer] in
                    guard let uiContainer else { throw StateInspectionError.missing }
                    return try await uiContainer.stateReaders()
                })
            try inspection.registerRoot(
                "platform",
                readers: { [weak platform] in
                    guard let platform else { throw StateInspectionError.missing }
                    return try await platform.stateReaders()
                })
            try inspection.registerRoot(
                "storage",
                readers: { [weak storage] in
                    guard let storage else { throw StateInspectionError.missing }
                    return try await storage.stateReaders()
                })
            try inspection.registerRoot(
                "model",
                readers: { [weak model] in
                    guard let model else { throw StateInspectionError.missing }
                    return try await model.stateReaders()
                })
            try inspection.registerRoot(
                "actions",
                readers: { [weak actions] in
                    guard let actions else { throw StateInspectionError.missing }
                    return try await actions.stateReaders()
                })
            try inspection.registerRoot(
                "gateway",
                readers: { [weak gateway] in
                    guard let gateway else { throw StateInspectionError.missing }
                    return try await gateway.stateReaders()
                })
            try inspection.registerRoot(
                "agents",
                readers: { [weak agents] in
                    guard let agents else { throw StateInspectionError.missing }
                    return try await agents.stateReaders()
                })
        } catch {
            // Preserve bootstrap failure through the existing diagnostic path.
            inspection.rejectConfiguration(error)
            containerFailures.report(module: "app", component: "state", operation: "register", error: error)
        }
        agents.readState = { path in try await inspection.snapshot(path: path) }
        actionAssembly.agents = agents
        let home = uiContainer.home
        let homePreparation = ForegroundPreparation(
            steps: {
                model.preparationSteps(for: agents.foregroundModelRequirements).map { step in
                    ForegroundPreparation.Step(
                        id: step.id, isReady: step.isReady,
                        prepare: { report in
                            try await step.prepare { await report($0) }
                        })
                }
            }, canPrepare: { !home.conversation.hasActiveInteraction },
            project: { [weak home] state in
                let value: HomeModelPreparation
                switch state {
                case .inactive: value = .inactive
                case .checking: value = .checking
                case .preparing(let component): value = .preparing(component)
                case .ready: value = .ready
                case .deferred: value = .deferred
                case .failed(let component, let message): value = .failed(component: component, message: message)
                }
                home?.presentModelPreparation(value)
                agents.reportModelPreparation(loading: value.isLoading)
            },
            onValidationFailure: { component, error in
                containerFailures.report(
                    module: "app", component: "homePreparation", operation: "verify." + component, error: error)
            })
        return Services(
            registry: registry, containerFailures: containerFailures,
            uiContainer: uiContainer, platform: platform, storage: storage, model: model,
            actions: actions, gateway: gateway, agents: agents, inspection: inspection, actionAssembly: actionAssembly,
            ui: ApplicationPresentation(features: agents, home: home), homePreparation: homePreparation)
    }
}
