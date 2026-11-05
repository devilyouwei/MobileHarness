import StorageChat
@_exported import StorageCore
import StorageDevices
import StorageFiles
import StorageMedia
import StorageTasks

/// Only domain protocols escape the backend selection boundary.
public struct DatabaseRepositories: Sendable {
    public let workspaces: any WorkspaceRepository
    public let chat: any ChatRepository
    public let tasks: any TaskRepository
    public let media: any MediaRepository
    public let devices: any DeviceRepository

    public init(
        chat: any ChatRepository, tasks: any TaskRepository, media: any MediaRepository, devices: any DeviceRepository,
        workspaces: any WorkspaceRepository
    ) {
        self.workspaces = workspaces
        self.chat = chat
        self.tasks = tasks
        self.media = media
        self.devices = devices
    }
}

public protocol DatabaseStorage: Sendable {
    var workspaces: any WorkspaceRepository { get throws }
    var chat: any ChatRepository { get throws }
    var tasks: any TaskRepository { get throws }
    var media: any MediaRepository { get throws }
    var devices: any DeviceRepository { get throws }
    func stateSnapshot() async throws -> StorageStateSnapshot
    func start() async throws
    func stop() async throws
}

/// Backend lifecycle is Runtime; no repository getter or database operation is performed by inspection.
public enum DatabasePhase: String, CaseIterable, Sendable {
    case unknown, cold, starting, ready, stopping, stopped, failed
}
extension DatabaseStorage {
    public func stateSnapshot() async throws -> StorageStateSnapshot {
        try Task.checkCancellation()
        return .init(
            path: "storage.database", runtime: ["phase": .unknown],
            stateValues: ["runtime.phase": DatabasePhase.allCases.map(\.rawValue)])
    }
}
