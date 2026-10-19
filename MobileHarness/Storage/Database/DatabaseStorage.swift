import StorageChat
import StorageDevices
import StorageMedia
import StorageTasks

/// Only domain protocols escape the backend selection boundary.
public struct DatabaseRepositories: Sendable {
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

public protocol DatabaseStorage: Sendable {
    var chat: any ChatRepository { get throws }
    var tasks: any TaskRepository { get throws }
    var media: any MediaRepository { get throws }
    var devices: any DeviceRepository { get throws }
    func start() async throws
    func stop() async throws
}
