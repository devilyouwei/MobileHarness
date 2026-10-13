import AgentCore
import Foundation

/// Photographer business service entry point; tracking policy is a co-located component.
public actor PhotographerAgent: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    private let contextRepository: AgentContextRepository<PhotographerContextState>
    private let preprocessor = PhotographerSignalPreprocessor()
    private let contextBuilder = PhotographerContextBuilder()

    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let sessionID: UUID
    private var trackingSessionID: UUID?
    private var camera = PhotographerCameraWorkflow()
    private let controlsArm: Bool
    private let controlAvailable: @Sendable () async -> Bool
    private var lifecycle: AgentLifecycle = .registered
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var lastPoseReceivedAt: ContinuousClock.Instant?
    private var tracking = PhotographerTrackingPolicy()
    private var processed = 0
    private var outputSequence: UInt64 = 0

    private static let aimPermission = InternalTool(path: "NexArm.Tracking.aim", required: ["base", "pitch"])

    private let taskCoordinator: AgentFixedTaskCoordinator<PhotographerContextState>
    private var taskPump: Task<Void, Never>?
    private var fixedTaskInputs: [UUID: AgentInput] = [:]
    private let admission = AgentAdmissionGate(capacity: 32)

    // MARK: - Registration

    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try PhotographerCameraWorkflow.runtimeCapabilities(capabilities).adding(internalTools: [aimPermission])
    }

    public init(
        sessionID: UUID, configuration: AgentConfiguration? = nil, controlsArm: Bool = false,
        outputCapacity: Int = PhotographerSignalPreprocessor.outputCapacity,
        controlAvailable: @escaping @Sendable () async -> Bool = { true },
        context: AgentContextRepository<PhotographerContextState>? = nil
    ) throws {
        guard (1...8192).contains(outputCapacity) else { throw CommunicationError.invalidPayload }
        self.contextRepository =
            context ?? AgentContextRepository(agent: .photographer, scope: UUID(), state: PhotographerContextState())
        guard contextRepository.agentID == .photographer else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: "Photographer")
        guard configuration.agentID == .photographer else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Photographer",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.communication, .actionCall, .toolCall, .control, .scheduling],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
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

    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        try await taskCoordinator.start()
        lifecycle = .running
        taskPump = Task { [taskCoordinator] in
            for await envelope in taskCoordinator.outputs {
                guard !Task.isCancelled else { return }
                if !relay(envelope) {
                    await taskCoordinator.stop()
                    return
                }
            }
        }
    }

    public func pause() async throws {
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        await taskCoordinator.pause()
        lifecycle = .paused
        lastPoseReceivedAt = nil
        tracking.reset()
    }

    public func resume() async throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        await taskCoordinator.resume()
        lifecycle = .running
    }

    public func stop() async {
        admission.close()
        lifecycle = .stopped
        trackingSessionID = nil
        camera.reset()
        lastPoseReceivedAt = nil
        tracking.reset()
        fixedTaskInputs.removeAll()
        await taskCoordinator.stop()
        taskPump?.cancel()
        await taskPump?.value
        taskPump = nil
        continuation.finish()
    }

    /// Trusted host attachment: exactly one vision scope, independent of root camera requests.
    public func bindTracking(sessionID: UUID) async throws {
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
    public func unbindTracking(sessionID: UUID) async throws {
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
        if case .observation(let message) = input.payload, message.contract == CameraStateObservation.contract {
            try await receiveCameraState(input, message: message)
            return
        }
        if await taskCoordinator.ownsFeedback(input) {
            try await taskCoordinator.receive(input)
            return
        }
        var input = input
        if case .observation(let message) = input.payload, let signal = message.content(as: AgentTaskSignal.self) {
            if signal.kind == .cancel,
                let original = fixedTaskInputs.values.first(where: { $0.taskScope?.id == signal.scope.id })
            {
                try await taskCoordinator.admitFixedTask(signal, input: input)
                try await contextRepository.update { $0.state.cameraRequestID = nil }
                camera.retire(original.id)
                fixedTaskInputs[original.id] = nil
                try emit(.control("agent.error: task cancelled"), input: original, sequence: 0)
                try await taskCoordinator.reportFixedTask(
                    signal.scope, input: original,
                    result: ToolResult(callID: original.id, value: "Task cancelled", isError: true), status: .cancelled)
                return
            }
            if signal.kind == .cancel || signal.businessContract == "runtime.taskTermination"
                || signal.businessContract == AgentTaskContent.contract
            {
                try await taskCoordinator.receive(input)
                return
            }
            let fixed = try AgentFixedTaskInput.unwrap(signal, input: input, executor: descriptor.id)
            guard fixedTaskInputs.count < 32 else { throw CommunicationError.capacityExceeded }
            try await taskCoordinator.admitFixedTask(signal, input: input)
            fixedTaskInputs[fixed.id] = fixed
            input = fixed
        }

        try await admission.acquire()
        defer { admission.release() }
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
        let decision = try contextBuilder.build(state: selection, batch: selection.batch())
        input = decision.input
        if input.payload.kind == .toolResult
            || {
                if case .observation(let message) = input.payload { return message.photographerCamera != nil }
                return false
            }()
        {
            guard lifecycle == .running else { throw HarnessError.notRunning }
            guard !input.metadata.expired else { throw CommunicationError.expired }
            var next = camera
            let (result, original) = try next.receive(input, rootSessionID: sessionID)
            try await prepareSignal(input, cameraRequestID: next.requestID)
            guard lifecycle == .running else { throw HarnessError.notRunning }
            camera = next
            do { try emit(result, input: original, sequence: input.metadata.sequence) } catch {
                if case .toolCall(let call) = result { camera.retire(call.id) }
                throw error
            }
            processed += 1
            return
        }
        guard input.sessionID == trackingSessionID, input.metadata.source == AgentID.visionPerception.rawValue else {
            throw CommunicationError.unauthorized
        }
        guard case .pose(let pose)? = input.payload.perception else { throw HarnessError.unsupportedInput }
        do { try pose.validate() } catch { throw CommunicationError.invalidPayload }
        guard lastSequence.map({ pose.sequence > $0 }) ?? true,
            lastTimestamp.map({ pose.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        if let lastPoseReceivedAt, ContinuousClock.now - lastPoseReceivedAt >= .seconds(1) {
            tracking.reset()
        }
        if let person = pose.people.first,
            PhotographerTrackingPolicy.aimPoint(person, width: pose.width, height: pose.height) != nil
        {
            lastPoseReceivedAt = .now
        }
        lastSequence = pose.sequence
        lastTimestamp = pose.timestamp
        processed += 1
        guard lifecycle == .running else { return }
        let available = await controlAvailable()
        guard lifecycle == .running, trackingSessionID == input.sessionID, lastSequence == pose.sequence else { return }
        guard available else {
            tracking.reset()
            return
        }
        guard controlsArm, let aim = tracking.nextAim(pose) else { return }
        let call = try Self.aimPermission.call(["base": String(aim.base), "pitch": String(aim.pitch)])
        try emit(.toolCall(call), input: input, sequence: pose.sequence)
        tracking.commit(base: aim.base, pitch: aim.pitch, timestamp: pose.timestamp)
    }

    // MARK: - Output

    private func emit(_ output: AgentOutput, input: AgentInput, sequence: UInt64) throws {
        outputSequence += 1
        switch continuation.yield(
            OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: outputSequence))
        {
        case .enqueued: return
        case .dropped:
            throw HarnessError.queueFull
        case .terminated:
            throw HarnessError.notRunning
        @unknown default: throw HarnessError.queueFull
        }
    }

    private func relay(_ envelope: OutputEnvelope) -> Bool {
        outputSequence += 1
        let input = AgentInput(
            id: envelope.inputID, sessionID: envelope.sessionID, payload: .event("relay"),
            metadata: envelope.inputMetadata,
            turn: envelope.turn, taskScope: envelope.taskScope)
        let result = continuation.yield(
            OutputEnvelope(
                source: descriptor.id, input: input,
                output: envelope.output, sequence: outputSequence, roundID: envelope.roundID, callID: envelope.callID))
        if case .enqueued = result { return true }
        lifecycle = .failed
        continuation.finish()
        return false
    }

    // MARK: - Context

    private func receiveCameraState(_ input: AgentInput, message: AgentMessage) async throws {
        guard input.metadata.origin == .external, input.metadata.source == CameraStateObservation.source,
            input.sessionID == sessionID, input.metadata.contract == CameraStateObservation.contract,
            input.metadata.version == 1
        else { throw CommunicationError.unauthorized }
        try await admission.acquire()
        defer { admission.release() }
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard let value = message.content(as: CameraStateObservation.self),
            value.sequence == input.metadata.sequence
        else { throw CommunicationError.invalidPayload }
        _ = try message.validatedSize()
        try await contextRepository.update {
            guard value.sequence > ($0.state.cameraState?.sequence ?? 0) else { throw CommunicationError.outOfOrder }
            $0.state.cameraState = value
        }
        processed += 1
    }

    private func prepareSignal(_ input: AgentInput, cameraRequestID: UUID?) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if case .replaceLatest = disposition { return }
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback
        ) { context in
            context.state.cameraRequestID = cameraRequestID
        }
    }

    public func completeFixedTask(inputID: UUID, value: String?, failure: String? = nil) async throws {
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

    public func contextSnapshot() async throws -> AgentContext<PhotographerContextState> {
        try await contextRepository.snapshot()
    }
}
