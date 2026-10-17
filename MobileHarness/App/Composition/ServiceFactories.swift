import ActionBindings
import AgentBindings
import AppStorage
import Foundation
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
        let uiContainer: UIContainer
        let platform: PlatformContainer
        let storage: StorageContainer
        let artifacts: ArtifactServices
        let agents: ApplicationFeatures
        let ui: AgentApplicationUI
    }
    static func make() -> Services {
        let root = URL.applicationSupportDirectory.appendingPathComponent("MobileHarness", isDirectory: true)
        let registry = ApplicationContainer(root: root)
        let storage = registry.storage()
        let files = storage.files
        let uiContainer = registry.ui()
        let presentation = registry.cameraPresentation()
        let platform = registry.platform()
        let camera = platform.vision.camera
        let bluetooth = BluetoothWorkflow(
            state: BluetoothSettingsState(), link: platform.connectivity.bluetooth,
            makeDeviceRepository: { try storage.database.devices })
        let photos = CameraStorageFactory.make(
            repository: { try storage.database.media },
            files: { try files.file(files.photos) })
        let resources = root.appendingPathComponent("Models/installed", isDirectory: true)
        let artifacts = ArtifactServices(resources: resources, files: files)
        let agents = ApplicationFeatures(
            repositories: {
                return try ApplicationRepositories(
                    chat: storage.database.chat, tasks: storage.database.tasks, media: storage.database.media,
                    devices: storage.database.devices)
            }, state: storage.state, cache: storage.cache, files: files, photos: photos, camera: camera,
            cameraState: presentation.state,
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
            registry: registry, uiContainer: uiContainer, platform: platform, storage: storage, artifacts: artifacts,
            agents: agents,
            ui: AgentApplicationUI(features: agents))
    }
}
