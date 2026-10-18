import ActionBindings
import AgentBindings
import AppStorage
import Foundation
import Gateway
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
        let artifacts: ArtifactServices
        let agents: ApplicationFeatures
        let ui: AgentApplicationUI
    }
    static func make() -> Services {
        let root = URL.applicationSupportDirectory.appendingPathComponent("MobileHarness", isDirectory: true)
        let registry = ApplicationContainer(
            root: root, uiConfiguration: .init(settings: SettingsProviderAdapter.initial))
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
        let resources = root.appendingPathComponent("Models/installed", isDirectory: true)
        let artifacts = ArtifactServices(resources: resources, files: files)
        let agents = ApplicationFeatures(
            containerFailures: containerFailures,
            home: uiContainer.home, settings: uiContainer.settings, modelResources: uiContainer.modelResources,
            navigation: uiContainer.navigation, history: uiContainer.history, devices: uiContainer.devices,
            diagnostics: uiContainer.diagnostics,
            repositories: {
                return try ApplicationRepositories(
                    chat: storage.database.chat, tasks: storage.database.tasks, media: storage.database.media,
                    devices: storage.database.devices)
            }, state: storage.state, cache: storage.cache, files: files, photos: photos, camera: camera,
            cameraState: presentation.state, cameraPresentation: presentation,
            makeCamera: { bindings in
                CameraCoordinator(
                    camera: camera, presentation: presentation, photos: photos, photoCues: platform.audio.cue(.camera),
                    saveJPEG: { data in try await platform.vision.saveJPEG(data) },
                    nativeEvent: bindings.nativeEvent, makeRuntime: bindings.makeRuntime,
                    connectFrames: bindings.connectFrames)
            },
            bluetooth: bluetooth, audio: platform.audio, artifacts: artifacts,
            resources: resources)
        return Services(
            registry: registry, containerFailures: containerFailures,
            uiContainer: uiContainer, platform: platform, storage: storage, artifacts: artifacts,
            agents: agents,
            ui: AgentApplicationUI(features: agents))
    }
}
