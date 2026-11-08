import StorageChat
import StorageDevices
import StorageMedia
import StorageTasks

public struct AgentRepositories: Sendable {
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
        devices: any DeviceRepository
    ) {
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
