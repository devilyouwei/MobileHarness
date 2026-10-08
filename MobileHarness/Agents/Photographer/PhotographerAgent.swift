import AgentCore
import Foundation

/// Photographer business service entry point; tracking policy is a co-located component.
public actor PhotographerAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
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

    private static let aimPermission = InternalTool(path: "NexArm.Tracking.aim", required: ["base", "pitch"])

    // MARK: - Registration

    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try PhotographerCameraWorkflow.runtimeCapabilities(capabilities).adding(internalTools: [aimPermission])
    }

    public init(
        sessionID: UUID, configuration: AgentConfiguration? = nil, controlsArm: Bool = false,
        controlAvailable: @escaping @Sendable () async -> Bool = { true }
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Photographer")
        guard configuration.agentID == .photographer else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Photographer",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.toolCall, .control],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        self.sessionID = sessionID
        trackingSessionID = sessionID
        self.controlsArm = controlsArm
        self.controlAvailable = controlAvailable
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
        outputs = stream.stream
        continuation = stream.continuation
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        lifecycle = .running
    }

    public func pause() throws {
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        lifecycle = .paused
        lastPoseReceivedAt = nil
        tracking.reset()
    }

    public func resume() throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        lifecycle = .running
    }

    public func stop() async {
        lifecycle = .stopped
        trackingSessionID = nil
        camera.reset()
        lastPoseReceivedAt = nil
        tracking.reset()
        continuation.finish()
    }

    /// Read-only host signal for a usable tracking pose; sensor timestamps cannot extend freshness.
    public func hasFreshPose(maximumAge: Duration = .seconds(1)) -> Bool {
        guard lifecycle == .running, maximumAge > .zero, let lastPoseReceivedAt else { return false }
        return ContinuousClock.now - lastPoseReceivedAt < maximumAge
    }

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: processed)
    }

    /// Trusted host attachment: exactly one vision scope, independent of root camera requests.
    public func bindTracking(sessionID: UUID) throws {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard trackingSessionID == nil || trackingSessionID == self.sessionID else {
            throw CommunicationError.capacityExceeded
        }
        trackingSessionID = sessionID
        lastSequence = nil
        lastTimestamp = nil
        lastPoseReceivedAt = nil
        tracking.reset()
    }
    public func unbindTracking(sessionID: UUID) {
        guard trackingSessionID == sessionID else { return }
        trackingSessionID = nil
        lastSequence = nil
        lastTimestamp = nil
        lastPoseReceivedAt = nil
        tracking.reset()
    }
    public func cameraResult() -> ToolResult? { camera.lastResult }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        if input.payload.kind == .toolResult
            || {
                if case .observation(let message) = input.payload { return message.photographerCamera != nil }
                return false
            }()
        {
            guard lifecycle == .running else { throw HarnessError.notRunning }
            guard !input.metadata.expired else { throw CommunicationError.expired }
            let (result, original) = try camera.receive(input, rootSessionID: sessionID)
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

    // MARK: - Output admission

    private func emit(_ output: AgentOutput, input: AgentInput, sequence: UInt64) throws {
        switch continuation.yield(
            OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: sequence))
        {
        case .enqueued: return
        case .dropped:
            throw HarnessError.queueFull
        case .terminated:
            throw HarnessError.notRunning
        @unknown default: throw HarnessError.queueFull
        }
    }
}
