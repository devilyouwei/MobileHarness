import StorageChat
import StorageDevices
import StorageMedia
import StorageTasks

public struct AgentRepositories: Sendable {
    public let chat: any ChatRepository
    public let tasks: any TaskRepository
    public let media: any MediaRepository
    public let devices: any DeviceRepository
    public init(
        chat: any ChatRepository, tasks: any TaskRepository, media: any MediaRepository, devices: any DeviceRepository
    ) {
        self.chat = chat
        self.tasks = tasks
        self.media = media
        self.devices = devices
    }
}
