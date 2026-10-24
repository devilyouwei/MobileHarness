import Actions
import Agents
import AppLifecycle
import AppStorage
import Foundation
import Gateway
import ModelKitDefaults
import ModelKitRuntime
import PlatformKit
import Storage
import StorageCache
import StorageCore
import StorageMedia
import StorageSQLite
import StorageState
import UI

@MainActor enum ServiceFactories {
    struct Services {
        let registry: ApplicationContainer
        let containerFailures: ContainerFailureChannel
        let uiContainer: UIContainer
        let platform: PlatformContainer
        let storage: StorageContainer
        let model: ModelContainer
        let agents: AgentContainer
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
        let bluetooth = BluetoothWorkflow(
            state: uiContainer.devices.presentation, link: platform.connectivity.bluetooth,
            makeDeviceRepository: { try storage.database.devices })
        let photos = CameraStorageFactory.make(
            repository: { try storage.database.media },
            files: { try files.file(files.photos) })
        let model = registry.model()
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
                }, state: storage.state, cache: storage.cache, files: files, photos: photos, camera: camera,
                cameraPresentation: presentation,
                cameraUI: uiContainer.camera,
                makeCamera: { bindings in
                    CameraCoordinator(
                        camera: camera, presentation: presentation, photos: photos,
                        photoCues: platform.audio.cue(.camera),
                        saveJPEG: { data in try await platform.vision.saveJPEG(data) },
                        makeRuntime: bindings.makeRuntime,
                        connectPerception: bindings.connectPerception)
                },
                bluetooth: bluetooth, audio: platform.audio,
                languageModels: model.language, speechModels: model.speech, visionModels: model.vision,
                modelArtifacts: model.artifacts, memoryPressure: { await model.handleMemoryPressure() })
        }
        let home = uiContainer.home
        let homePreparation = ForegroundPreparation(
            steps: {
                var steps: [ForegroundPreparation.Step] = [
                    .init(
                        id: "language",
                        isReady: {
                            switch try await model.language.status() {
                            case .ready, .unmanaged: true
                            default: false
                            }
                        }, prepare: { report in try await model.language.warmup(reportLoading: { await report($0) }) })
                ]
                for (id, capability) in [
                    ("recognition", ProvidedCapability.recognition), ("synthesis", .synthesis),
                    ("voiceActivity", .voiceActivity),
                ] {
                    steps.append(
                        .init(
                            id: id,
                            isReady: {
                                switch try await model.speech.status(capability) {
                                case .ready, .unmanaged: true
                                default: false
                                }
                            },
                            prepare: { report in
                                try await model.speech.warmup(capability, reportLoading: { await report($0) })
                            }))
                }
                if uiContainer.camera.state.isEnabled {
                    steps.append(
                        .init(
                            id: "vision",
                            isReady: {
                                switch try await model.vision.status() {
                                case .ready, .unmanaged: true
                                default: false
                                }
                            }, prepare: { report in try await model.vision.warmup(reportLoading: { await report($0) }) }
                        ))
                }
                return steps
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
            agents: agents,
            ui: ApplicationPresentation(features: agents, home: home), homePreparation: homePreparation)
    }
}
