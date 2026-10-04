import AgentCore
import Foundation
import Types

/// Camera-motion policy. Consumes published pose observations and, when enabled, emits one arm Tool.
public actor PhotographerAgent: Agent {
    private static let aimPermission = InternalTool(path: "Robot.aim", required: ["base", "pitch"])
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let sessionID: UUID
    private let controlsArm: Bool
    private let controlAvailable: @Sendable () async -> Bool
    private var lifecycle: AgentLifecycle = .registered
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var lastAim: (base: Double, pitch: Double, time: TimeInterval)?
    private var filteredBase = 0.0
    private var filteredPitch = 0.0
    private var commandedBase = 0.0
    private var commandedPitch = 0.0
    private var processed = 0

    public init(
        sessionID: UUID, configuration: AgentConfiguration? = nil, controlsArm: Bool = false,
        controlAvailable: @escaping @Sendable () async -> Bool = { true }
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Photographer")
        guard configuration.agentID == .photographer else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Photographer",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.toolCall],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        self.sessionID = sessionID
        self.controlsArm = controlsArm
        self.controlAvailable = controlAvailable
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

    public func receive(_ input: AgentInput) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == sessionID else { throw CommunicationError.unauthorized }
        guard case .pose(let pose)? = input.payload.perception else { throw HarnessError.unsupportedInput }
        do { try pose.validate() } catch { throw CommunicationError.invalidPayload }
        guard lastSequence.map({ pose.sequence > $0 }) ?? true,
            lastTimestamp.map({ pose.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        lastSequence = pose.sequence
        lastTimestamp = pose.timestamp
        processed += 1
        guard lifecycle == .running else { return }
        let available = await controlAvailable()
        guard lifecycle == .running, lastSequence == pose.sequence else { return }
        guard available else {
            lastAim = nil
            filteredBase = 0
            filteredPitch = 0
            commandedBase = 0
            commandedPitch = 0
            return
        }
        guard let aim = nextAim(pose) else { return }
        let call = try Self.aimPermission.call(["base": String(aim.base), "pitch": String(aim.pitch)])
        try emit(.toolCall(call), input: input, sequence: pose.sequence)
        commandedBase = aim.base
        commandedPitch = aim.pitch
        lastAim = (aim.base, aim.pitch, pose.timestamp)
    }

    /// First published person. Nose at confidence ≥ 0.3 inside the image, otherwise the midpoint of such joints.
    /// `base` turns the base; `pitch` tips the wrist. Both advance in limited steps from the last command.
    private func nextAim(_ pose: PoseObservation) -> (base: Double, pitch: Double)? {
        guard controlsArm, let person = pose.people.first else { return nil }
        guard let point = aimPoint(person, width: pose.width, height: pose.height) else { return nil }
        let errorX = point.x / Double(pose.width) - 0.5
        let errorY = point.y / Double(pose.height) - 0.5
        let baseError = track(&filteredBase, error: errorX)
        let pitchError = track(&filteredPitch, error: errorY)
        if let lastAim, pose.timestamp - lastAim.time < 0.2 { return nil }
        let dt = lastAim.map { min(0.4, max(0.05, pose.timestamp - $0.time)) } ?? 0.2
        let baseStep = rateStep(baseError, gain: 1.15, limit: 0.55, dt: dt)
        let pitchStep = rateStep(pitchError, gain: 0.85, limit: 0.40, dt: dt)
        guard abs(baseStep) >= 0.004 || abs(pitchStep) >= 0.004 else { return nil }
        let base = min(1, max(-1, commandedBase + baseStep))
        let pitch = min(0.7, max(-0.7, commandedPitch + pitchStep))
        guard base != commandedBase || pitch != commandedPitch else { return nil }
        return (base, pitch)
    }

    /// Soft dead zone, then a smoothed error. A direction change starts from half the new error.
    private func track(_ filtered: inout Double, error: Double) -> Double {
        let zone = 0.04
        let magnitude = abs(error)
        let shaped: Double
        if magnitude <= zone {
            shaped = 0
        } else {
            let extra = magnitude - zone
            shaped = copysign(extra * min(1, extra / zone), error)
        }
        if shaped == 0 {
            filtered = 0
        } else if filtered * shaped < 0 {
            filtered = shaped * 0.5
        } else if filtered == 0 {
            filtered = shaped
        } else {
            filtered += 0.55 * (shaped - filtered)
        }
        return filtered
    }

    private func rateStep(_ error: Double, gain: Double, limit: Double, dt: TimeInterval) -> Double {
        let rate = min(limit, max(-limit, gain * error))
        return rate * dt
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
        case .dropped:
            throw HarnessError.queueFull
        case .terminated:
            throw HarnessError.notRunning
        @unknown default: throw HarnessError.queueFull
        }
    }
}
