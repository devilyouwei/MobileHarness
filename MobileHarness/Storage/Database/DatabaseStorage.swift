import StorageChat
@_exported import StorageCore
import StorageDevices
import StorageFiles
import StorageMedia
import StorageTasks

/// Only domain protocols escape the backend selection boundary.
public struct DatabaseRepositories: Sendable {
    public let workspaces: any WorkspaceRepository
    public let assistantConversations: any AssistantConversationRepository
    public let assistantMessages: any AssistantMessageRepository
    public let assistantTasks: any AssistantTaskRepository & AssistantTaskSummaryRepository
    public let writerMessages: any WriterMessageRepository
    public let writerExecutions: any WriterExecutionRepository
    public let agentMessages: any AgentMessageRepository
    public let logs: any ModelRequestLogRepository
    public let media: any MediaRepository
    public let devices: any DeviceRepository

    public init(
        assistantConversations: any AssistantConversationRepository, assistantMessages: any AssistantMessageRepository,
        assistantTasks: any AssistantTaskRepository & AssistantTaskSummaryRepository,
        writerMessages: any WriterMessageRepository, writerExecutions: any WriterExecutionRepository,
        agentMessages: any AgentMessageRepository, logs: any ModelRequestLogRepository, media: any MediaRepository,
        devices: any DeviceRepository,
        workspaces: any WorkspaceRepository
    ) {
        self.workspaces = workspaces
        self.assistantConversations = assistantConversations
        self.assistantMessages = assistantMessages
        self.assistantTasks = assistantTasks
        self.writerMessages = writerMessages
        self.writerExecutions = writerExecutions
        self.agentMessages = agentMessages
        self.logs = logs
        self.media = media
        self.devices = devices
    }
}

public protocol DatabaseStorage: Sendable {
    var workspaces: any WorkspaceRepository { get throws }
    var assistantConversations: any AssistantConversationRepository { get throws }
    var assistantMessages: any AssistantMessageRepository { get throws }
    var assistantTasks: any AssistantTaskRepository & AssistantTaskSummaryRepository { get throws }
    var writerMessages: any WriterMessageRepository { get throws }
    var writerExecutions: any WriterExecutionRepository { get throws }
    var agentMessages: any AgentMessageRepository { get throws }
    var logs: any ModelRequestLogRepository { get throws }
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
