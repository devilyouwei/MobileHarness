import AgentCore
import Foundation

/// Camera-motion policy. Consumes published pose observations and, when enabled, emits one arm Tool.
public actor PhotographerAgent: Agent {
    private static let aimPermission = InternalTool(path: "Robot.aim", required: ["base", "pitch"])
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let sessionID: UUID
    private let controlsArm: Bool
    private var lifecycle: AgentLifecycle = .registered
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var lastAim: (base: Double, pitch: Double, time: TimeInterval)?
    private var processed = 0

    public init(sessionID: UUID, configuration: AgentConfiguration? = nil, controlsArm: Bool = false) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Photographer")
        guard configuration.agentID == .photographer else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Photographer",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.toolCall],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        self.sessionID = sessionID
        self.controlsArm = controlsArm
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
        outputs = stream.stream
        continuation = stream.continuation
    }

    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(internalTools: [aimPermission])
    }

    public func start() throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        lifecycle = .running
    }
    public func pause() throws {
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        lifecycle = .paused
    }
    public func resume() throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        lifecycle = .running
    }
    public func stop() async {
        lifecycle = .stopped
        continuation.finish()
    }
    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: processed)
    }

    public func receive(_ input: AgentInput) throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == sessionID else { throw CommunicationError.unauthorized }
        guard case .observation(.pose(let pose)) = input.payload else { throw HarnessError.unsupportedInput }
        guard lastSequence.map({ pose.sequence > $0 }) ?? true,
            lastTimestamp.map({ pose.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        lastSequence = pose.sequence
        lastTimestamp = pose.timestamp
        processed += 1
        guard lifecycle == .running, let aim = nextAim(pose) else { return }
        let call = try Self.aimPermission.call(["base": String(aim.base), "pitch": String(aim.pitch)])
        try emit(.toolCall(call), input: input, sequence: pose.sequence)
        lastAim = (aim.base, aim.pitch, pose.timestamp)
    }

    /// First published person. Nose at confidence ≥ 0.3 inside the image, otherwise the midpoint of such joints.
    private func nextAim(_ pose: PoseObservation) -> (base: Double, pitch: Double)? {
        guard controlsArm, let person = pose.people.first else { return nil }
        guard let point = aimPoint(person, width: pose.width, height: pose.height) else { return nil }
        let base = (point.x / Double(pose.width) - 0.5) * 0.8
        let pitch = (point.y / Double(pose.height) - 0.5) * 0.8
        if let lastAim {
            let waited = pose.timestamp - lastAim.time >= 0.2
            let moved = hypot(base - lastAim.base, pitch - lastAim.pitch) >= 0.02
            guard waited, moved else { return nil }
        }
        return (base, pitch)
    }

    private func aimPoint(_ person: [PoseObservation.Joint], width: Int, height: Int) -> (x: Double, y: Double)? {
        func usable(_ joint: PoseObservation.Joint) -> Bool {
            joint.confidence >= 0.3 && joint.x.isFinite && joint.y.isFinite && joint.x >= 0 && joint.y >= 0
                && Double(joint.x) <= Double(width) && Double(joint.y) <= Double(height)
        }
        if usable(person[0]) { return (Double(person[0].x), Double(person[0].y)) }
        let visible = person.filter(usable)
        guard !visible.isEmpty else { return nil }
        let count = Double(visible.count)
        let x = visible.reduce(0.0) { $0 + Double($1.x) } / count
        let y = visible.reduce(0.0) { $0 + Double($1.y) } / count
        return (x, y)
    }

    private func emit(_ output: AgentOutput, input: AgentInput, sequence: UInt64) throws {
        switch continuation.yield(
            OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: sequence))
        {
        case .enqueued: return
        case .dropped, .terminated:
            lifecycle = .failed
            continuation.finish()
            throw HarnessError.queueFull
        @unknown default: throw HarnessError.queueFull
        }
    }
}
