import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

public actor WriterAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    let model: @Sendable () async throws -> ChatModel
    let streaming: any ArtifactStreaming
    let history: WriterHistoryStore?
    let communications: any AgentMessageRepository
    let executions: any WriterExecutionRepository
    let startBackground: WriterBackgroundExecution.Start?
    let language: @Sendable () -> String
    let island: WriterIslandPresentation
    var messaging: AgentMessaging?
    var consumer: GatewayOutputConsumer?
    var lifecycle = AgentLifecycle.registered
    var workers: [String: Task<Void, Never>] = [:]
    var backgroundRuns: [String: UUID] = [:]
    var expiredBackgroundRuns: Set<String> = []
    var backgroundFailure: String?
    var previews: [String: WriterPreview] = [:]
    var sceneActive = true
    var updates: [String: [String]] = [:]
    var inputs: [String: AgentInput] = [:]
    var requests: [String: Request] = [:]
    var failures: [String: String] = [:]
    var models: [String: ChatModel] = [:]
    var waiting: [String: String] = [:]
    var suspending: Set<String> = []
    var cancelling: Set<String> = []
    var cancellationAdmissions: [String: Task<Void, Error>] = [:]
    struct PendingReport: Sendable {
        let content: AgentTaskContent
        let scope: AgentTaskScope
        let input: AgentInput
    }
    // One pending fact per kind plus one immutable in-flight fact. The first draft and retry are emitted once.
    var pendingReports: [String: [PendingReport]] = [:]
    var reportWorker: Task<Void, Never>?
    var deliveringEvent: String?
    var deliveryFailures: [String: String] = [:]
    var eventSequences: [String: UInt64] = [:]
    var reportedMilestones: [String: Set<AgentTaskEvent.Kind>] = [:]
    var lastSteps: [String: String] = [:]
    var windowIDs: [String: String] = [:]
    var phases: [String: String] = [:]
    var inbox: [(AgentTaskRequest, AgentInput)] = []
    var inboxWorker: Task<Void, Never>?
    var finalizing: Set<String> = []
    var preparedWorkspaces: Set<String> = []
    struct CreationKey: Hashable {
        let title: String
        let entry: String
    }
    struct CreationReservation {
        let workspaceID: String
        var entered = false
    }
    var creations: [String: [CreationKey: CreationReservation]] = [:]
    var completedLibraryOperations: Set<String> = []
    var searchMatches: [String: Set<String>] = [:]
    var workspaceContexts: [String: WriterWorkspaceContext] = [:]
    var processed = 0
    var sequence: UInt64 = 0
    static let workspacePath = "Artifacts.Workspace."
    private static let internalWorkspaceTools = ["start", "resume", "describe", "preview", "publish"]

    public static func capabilities() throws -> CapabilityRegistry {
        let editing = try WriterControlDomain.editing.registry()
        let lifecycle = try AgentConfigurations.registry(
            internalWorkspaceTools.map {
                .init(path: workspacePath + $0, callType: "tool", alias: $0, channel: nil)
            })
        return try CapabilityRegistry(
            tools: editing.tools.filter { !WriterLocalTools.contains($0.path) },
            internalTools: lifecycle.tools.map {
                .init(path: $0.path, required: $0.requiredParameters, optional: $0.optionalParameters)
            } + [
                .init(path: "UI.Island.present", required: ["activityID", "revision", "content"]),
                .init(path: "UI.Island.end", required: ["activityID", "revision"]),
            ])
    }
    public init(
        model: @escaping @Sendable () async throws -> ChatModel, streaming: any ArtifactStreaming,
        history: WriterHistoryStore? = nil, executions: any WriterExecutionRepository,
        communications: any AgentMessageRepository, startBackground: WriterBackgroundExecution.Start? = nil,
        language: @escaping @Sendable () -> String = { "en" }
    ) throws {
        guard executions.storageScope == communications.storageScope,
            history.map({ $0.storageScope == executions.storageScope }) ?? true
        else { throw RecordStorageError.invalidRecord }
        self.executions = executions
        self.communications = communications
        self.startBackground = startBackground
        self.language = language
        island = WriterIslandPresentation(language: language)
        self.history = history
        self.model = model
        self.streaming = streaming
        let config = try AgentConfigurations.load(named: "Writer")
        descriptor = AgentDescriptor(
            category: config.category, publicationChannels: config.communication.publicationChannels,
            id: .writer, name: "Writer", inputs: config.communication.inputKinds,
            outputs: [.toolCall, .communication, .control], capabilities: try Self.capabilities())
        let pair = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(16))
        outputs = pair.stream
        continuation = pair.continuation
    }
    public func bind(_ consumer: GatewayOutputConsumer, messaging: AgentMessaging) async {
        self.consumer = consumer
        self.messaging = messaging
        await island.bind { [weak self] operation, parameters, session in
            guard let self else { throw WriterFailure.unavailable }
            try await self.presentIsland(operation, parameters: parameters, sessionID: session)
        }
    }
    public func start() async throws {
        guard lifecycle == .registered, consumer != nil else { throw WriterFailure.unavailable }
        lifecycle = .running
        await island.start()
    }
    public func setSceneActive(_ active: Bool) async {
        sceneActive = active
        for preview in Array(previews.values) { await preview.setSceneActive(active) }
    }
    public func pause() async throws {
        guard lifecycle == .running else { return }
        lifecycle = .paused
        inboxWorker?.cancel()
        await inboxWorker?.value
        for admission in Array(cancellationAdmissions.values) { _ = await admission.result }
        let selected = workers
        suspending.formUnion(selected.keys)
        for worker in selected.values { worker.cancel() }
        for id in selected.keys { await streaming.revoke(delegateID: id) }
        for worker in selected.values { await worker.value }
        reportWorker?.cancel()
        await reportWorker?.value
        for (id, _) in requests {
            await island.update(delegateID: id, phase: .paused)
        }
    }
    public func resume() async throws {
        guard lifecycle == .paused else { return }
        lifecycle = .running
        for (id, _) in requests {
            await island.update(delegateID: id, phase: waiting[id] == nil ? .running : .waitingUser)
        }
        for (id, input) in inputs where workers[id] == nil {
            guard let scope = input.taskScope else { continue }
            if waiting[id] == nil, let request = requests[id] {
                workers[id] = Task { await run(request, input: input, scope: scope) }
            }
        }
        startReports()
        startInbox()
    }
    public func stop() async {
        lifecycle = .stopped
        inboxWorker?.cancel()
        await inboxWorker?.value
        for (message, input) in inbox {
            await rejectMessage(message, text: "Writer has stopped.", input: input)
        }
        inbox.removeAll()
        for admission in Array(cancellationAdmissions.values) { _ = await admission.result }
        let selected = workers
        for worker in selected.values { worker.cancel() }
        for id in selected.keys { await streaming.revoke(delegateID: id) }
        for worker in selected.values { await worker.value }
        for (id, input) in inputs {
            if let scope = input.taskScope {
                do {
                    try await report(
                        "Writing was interrupted. The draft was kept.", scope: scope, input: input, status: .failed,
                        persistedStatus: "interrupted")
                } catch {
                    failures[id] = String(String(describing: error).prefix(256))
                }
            }
        }
        await reportWorker?.value
        for id in Array(inputs.keys) { forget(id) }
        reportWorker?.cancel()
        await reportWorker?.value
        pendingReports.removeAll()
        reportedMilestones.removeAll()
        await island.stop()
        messaging = nil
        continuation.finish()
        consumer = nil
    }
    public func status() -> AgentStatus {
        .init(
            lifecycle: lifecycle, queuedInputs: inbox.count + updates.values.reduce(0) { $0 + $1.count },
            processedInputs: processed)
    }
    var modelChanging = false

    func beginModelChange() async {
        modelChanging = true
        await inboxWorker?.value
        let active = workers
        for id in active.keys {
            guard let input = inputs[id], let scope = input.taskScope else { continue }
            await cancelExecution(scope, original: input)
        }
        for worker in active.values { await worker.value }
    }

    func endModelChange() {
        modelChanging = false
        startInbox()
    }

    var presentationCopy: AppLanguage { AppLanguage(preferredLanguage: language()) }

    struct Request {
        var request: String
        var workspaceID: String? = nil
        var language = "en"
    }
}
