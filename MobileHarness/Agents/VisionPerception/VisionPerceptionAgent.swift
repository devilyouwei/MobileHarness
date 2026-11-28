import AgentCore
import Foundation
import Gateway
import StorageCore
import UI

/// VisionPerception business service entry point; tracking policy is a co-located component.
public actor VisionPerceptionAgent: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    let island = AgentIslandPublication()
    public func finishPresentation() async { await island.stop() }
    public var presentationFailure: String? { get async { await island.lastFailure } }
    var cameraFacts: Task<Void, Never>?
    var cameraFactSequence: UInt64 = 0
    let cameraObservationFailure: @Sendable (any Error) -> Void
    let uiAlbum: UIAlbumContainer?
    let uiCamera: UICameraContainer?
    var uiInputs = AgentUIInputs()
    var uiExecution = AgentUIExecution()
    let contextRepository: AgentContextRepository<CameraTransactionContextState>
    let preprocessor = CameraTransactionSignalPreprocessor()
    let contextBuilder = CameraTransactionContextBuilder()

    let continuation: AsyncStream<OutputEnvelope>.Continuation
    let sessionID: String
    var trackingSessionID: String?
    var camera = CameraCaptureWorkflow()
    let controlsArm: Bool
    let controlAvailable: @Sendable () async -> Bool
    var lifecycle: AgentLifecycle = .registered
    var lastSequence: UInt64?
    var lastTimestamp: TimeInterval?
    var lastPoseReceivedAt: ContinuousClock.Instant?
    var tracking = PoseTrackingPolicy()
    var processed = 0
    var outputSequence: UInt64 = 0

    static let aimPermission = InternalTool(path: "NexArm.Tracking.aim", required: ["base", "pitch"])

    let taskCoordinator: AgentFixedTaskCoordinator<CameraTransactionContextState>
    var fixedTaskInputs: [String: AgentInput] = [:]
    let admission = AgentAdmissionGate(capacity: 32)

    // MARK: - Registration

    public static func runtimeCapabilities() throws -> CapabilityRegistry {
        try CameraCaptureWorkflow.runtimeCapabilities(PoseInferenceWorkflow.runtimeCapabilities()).adding(
            internalTools: [
                aimPermission, InternalTool(path: "Camera.Album.perform"),
            ] + AgentIslandPublication.permissions)
    }

    public init(
        sessionID: String, configuration: AgentConfiguration? = nil, uiCamera: UICameraContainer? = nil,
        controlsArm: Bool = false, uiAlbum: UIAlbumContainer? = nil,
        cameraObservationFailure: @escaping @Sendable (any Error) -> Void = { _ in },
        outputCapacity: Int = CameraTransactionSignalPreprocessor.outputCapacity,
        controlAvailable: @escaping @Sendable () async -> Bool = { true },
        context: AgentContextRepository<CameraTransactionContextState>
    ) throws {
        guard (1...8192).contains(outputCapacity) else { throw CommunicationError.invalidPayload }
        self.cameraObservationFailure = cameraObservationFailure
        self.uiAlbum = uiAlbum
        self.uiCamera = uiCamera
        self.contextRepository = context
        guard contextRepository.agentID == .visionPerception else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: "VisionPerception")
        guard configuration.agentID == .visionPerception else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            category: configuration.category, publicationChannels: configuration.communication.publicationChannels,
            id: configuration.agentID, name: "VisionPerception",
            inputs: configuration.communication.inputKinds,
            outputs: [.communication, .toolCall, .control],
            capabilities: try Self.runtimeCapabilities())
        taskCoordinator = AgentFixedTaskCoordinator(context: self.contextRepository)
        self.sessionID = sessionID
        trackingSessionID = sessionID
        self.controlsArm = controlsArm
        self.controlAvailable = controlAvailable
        let stream = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
    }

    // MARK: - Lifecycle

    public func receiveRequest(_ request: AgentProtocolRequest) async throws -> AgentRequestReply {
        let input = request.input
        guard case .observation(let message) = input.payload, message.operation == request.operation else {
            throw CommunicationError.invalidPayload
        }
        if request.operation == .status {
            guard let query = message.content(as: AgentTaskQuery.self) else { throw CommunicationError.invalidPayload }
            return try await taskCoordinator.requestStatus(query, input: input)
        }
        if request.operation == .cancel, let query = message.content(as: AgentTaskQuery.self) {
            _ = try await taskCoordinator.requestStatus(query, input: input)
            try await receive(AgentFixedTaskInput.cancellation(query, input: input))
            return AgentRequestReply(requestID: input.id, reference: query.scope.id)
        }
        guard let signal = message.content(as: AgentTaskSignal.self),
            (request.operation == .submit && signal.kind == .request)
                || ([.update, .answer].contains(request.operation) && signal.kind == .input)
                || (request.operation == .cancel && signal.kind == .cancel)
        else { throw CommunicationError.invalidPayload }
        try await receive(input)
        return AgentRequestReply(requestID: input.id, reference: signal.scope.id)
    }
    public func bindMessaging(_ messaging: AgentMessaging) async {
        await taskCoordinator.bindMessaging(messaging)
    }
    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        try await taskCoordinator.start()
        lifecycle = .running

        try await startUIInputs()
    }

    public func pause() async throws {
        await stopUIInputs()
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        await taskCoordinator.pause()
        lifecycle = .paused
        lastPoseReceivedAt = nil
        tracking.reset()
    }

    public func resume() async throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        await stopUIInputs()
        await taskCoordinator.resume()
        lifecycle = .running
        try await startUIInputs()
    }

    public func stop() async {
        await stopUIInputs()
        await island.stop()
        uiExecution.consumer = nil
        admission.close()
        lifecycle = .stopped
        trackingSessionID = nil
        camera.reset()
        lastPoseReceivedAt = nil
        tracking.reset()
        fixedTaskInputs.removeAll()
        await taskCoordinator.stop()
        continuation.finish()
    }

    /// Trusted host attachment: exactly one vision scope, independent of root camera requests.
    public func bindTracking(sessionID: String) async throws {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard trackingSessionID == nil || trackingSessionID == self.sessionID else {
            throw CommunicationError.capacityExceeded
        }
        try await contextRepository.update { $0.state.trackingSessionID = sessionID }
        guard lifecycle == .running else { throw HarnessError.notRunning }
        trackingSessionID = sessionID
        lastSequence = nil
        lastTimestamp = nil
        lastPoseReceivedAt = nil
        tracking.reset()
    }
    public func unbindTracking(sessionID: String) async throws {
        guard trackingSessionID == sessionID else { return }
        try await contextRepository.update { $0.state.trackingSessionID = nil }
        trackingSessionID = nil
        lastSequence = nil
        lastTimestamp = nil
        lastPoseReceivedAt = nil
        tracking.reset()
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {
        if case .toolResult = input.payload { throw CommunicationError.invalidPayload }
        try await processInput(input)
    }

    // MARK: - Context

    public func completeFixedTask(inputID: String, value: String?, failure: String? = nil) async throws {
        guard let original = fixedTaskInputs.removeValue(forKey: inputID), let scope = original.taskScope else {
            return
        }
        try await taskCoordinator.reportFixedTask(
            scope, input: original,
            result: ToolResult(callID: inputID, value: failure ?? value ?? "Completed", isError: failure != nil))
    }

    // MARK: - Observability

    /// Read-only host signal for a usable tracking pose; sensor timestamps cannot extend freshness.
    public func hasFreshPose(maximumAge: Duration = .seconds(1)) -> Bool {
        guard lifecycle == .running, maximumAge > .zero, let lastPoseReceivedAt else { return false }
        return ContinuousClock.now - lastPoseReceivedAt < maximumAge
    }

    public func cameraResult() -> ToolResult? { camera.lastResult }

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: processed)
    }

    /// Passive State reflection, independent of persistence initialization.
    public func residentContext() async -> AgentContext<CameraTransactionContextState>? {
        await contextRepository.residentSnapshot()
    }

    public func contextSnapshot() async throws -> AgentContext<CameraTransactionContextState> {
        try await contextRepository.snapshot()
    }
}
