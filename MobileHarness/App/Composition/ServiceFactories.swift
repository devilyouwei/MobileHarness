import ActionBindings
import AgentBindings
import Foundation
import PlatformKit
import Storage
import StorageMedia
import StorageSQLite
import UI

@MainActor enum ServiceFactories {
    struct Services {
        let repositories: Result<SQLiteRepositories, any Error>
        let agents: ApplicationFeatures
        let ui: AgentApplicationUI
    }
    static func make() -> Services {
        let root = URL.applicationSupportDirectory.appendingPathComponent("MobileHarness", isDirectory: true)
        let repositories = Result {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let value = try SQLiteRepositories(url: root.appendingPathComponent("records.sqlite"))
            try value.recoverInFlight()
            return value
        }
        let camera = AppleCamera()
        let bluetooth = BluetoothWorkflow(
            state: BluetoothSettingsState(), link: NexArmBluetooth(),
            makeDeviceRepository: { try repositories.get().devices })
        let photos = CameraStorageFactory.make(
            repository: repositories.map { $0.media as any MediaRepository },
            root: root.appendingPathComponent("CapturedPhotos", isDirectory: true))
        let resources = root.appendingPathComponent("Models/installed", isDirectory: true)
        let artifacts = ArtifactServices(resources: resources)
        let agents = ApplicationFeatures(
            repositories: repositories.map {
                ApplicationRepositories(chat: $0.chat, tasks: $0.tasks, media: $0.media, devices: $0.devices)
            }, photos: photos, camera: camera, bluetooth: bluetooth, artifacts: artifacts, resources: resources)
        return Services(repositories: repositories, agents: agents, ui: AgentApplicationUI(features: agents))
    }
}
