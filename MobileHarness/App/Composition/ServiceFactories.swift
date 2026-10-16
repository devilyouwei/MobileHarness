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
        let camera = AppleCamera()
        let bluetooth = BluetoothWorkflow(
            state: BluetoothSettingsState(), link: NexArmBluetooth(),
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
            bluetooth: bluetooth, artifacts: artifacts, resources: resources)
        return Services(
            registry: registry, storage: storage, artifacts: artifacts, agents: agents,
            ui: AgentApplicationUI(features: agents))
    }
}
