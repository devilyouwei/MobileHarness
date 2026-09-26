import AgentCore
import Foundation
import ModelKit

/// Photography role. Pose overlay always runs. Arm aim runs only when `controlsArm` is set.
public actor PhotographerAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let pose: any PoseCapability
    private let sessionID: UUID
    private var lifecycle: AgentLifecycle = .registered
    private var pending: AgentInput?
    private var worker: Task<Void, Never>?
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var processed = 0
    private let controlsArm: Bool
    private var lastAim: (base: Double, pitch: Double, time: TimeInterval)?

    public init(
        pose: any PoseCapability, sessionID: UUID, configuration: AgentConfiguration? = nil, controlsArm: Bool = false
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Photographer")
        guard configuration.agentID == .photographer else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Photographer", inputs: [.image],
            outputs: [.actionCall, .control], capabilities: configuration.capabilities)
        self.pose = pose
        self.sessionID = sessionID
        self.controlsArm = controlsArm
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
        outputs = stream.stream
        continuation = stream.continuation
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
        drain()
    }
    public func stop() async {
        lifecycle = .stopped
        pending = nil
        worker?.cancel()
        await worker?.value
        continuation.finish()
    }
    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: pending == nil ? 0 : 1, processedInputs: processed)
    }
    public func receive(_ input: AgentInput) throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == sessionID else { throw ImageInputError.wrongSession }
        guard case .image(let image) = input.payload else { throw HarnessError.unsupportedInput }
        guard lastSequence.map({ image.sequence > $0 }) ?? true,
            lastTimestamp.map({ image.timestamp >= $0 }) ?? true
        else { throw ImageInputError.outOfOrder }
        lastSequence = image.sequence
        lastTimestamp = image.timestamp
        pending = input  // Explicit newest-frame replacement, never applied to Action/Tool outputs.
        drain()
    }
    private func drain() {
        guard lifecycle == .running, worker == nil, let input = pending else { return }
        pending = nil
        worker = Task { await infer(input) }
    }
    private func infer(_ input: AgentInput) async {
        defer {
            worker = nil
            drain()
        }
        do {
            guard case .image(let image) = input.payload else { throw HarnessError.unsupportedInput }
            let context = InferenceContext(requestID: input.id, conversationID: input.sessionID)
            let result = try await pose.estimatePose(
                PoseRequest(
                    image: ImageFrame(width: image.width, height: image.height, rgb: image.rgb), context: context))
            try Task.checkCancellation()
            guard lifecycle == .running || lifecycle == .paused else { return }
            guard result.context == context else {
                throw CapabilityError.invalidRequest("Pose result context mismatch")
            }
            let people = try result.people.prefix(6).map { person in
                guard person.keypoints.count == 17 else { throw CapabilityError.invalidRequest("Invalid COCO pose") }
                return try person.keypoints.enumerated().map { index, point in
                    guard point.joint.rawValue == index, point.x.isFinite, point.y.isFinite,
                        point.confidence.isFinite, (0...1).contains(point.confidence)
                    else { throw CapabilityError.invalidRequest("Invalid pose joint") }
                    let x = Double(point.x) / Double(image.width)
                    let y = Double(point.y) / Double(image.height)
                    // Bounded off-image transport; invisible points stay low confidence.
                    let visible = (0...1).contains(x) && (0...1).contains(y)
                    return PoseOverlay.Joint(
                        x: Int((max(-1, min(2, x)) * 10000).rounded()),
                        y: Int((max(-1, min(2, y)) * 10000).rounded()),
                        confidence: visible ? Int((point.confidence * 1000).rounded()) : 0)
                }
            }
            let overlay = PoseOverlay(
                sequence: image.sequence, timestamp: image.timestamp, rotation: image.rotation, people: people)
            let data = try JSONEncoder().encode(overlay)
            guard data.count <= 3000, let json = String(data: data, encoding: .utf8) else {
                throw CapabilityError.eventTooLarge
            }
            // Deterministic CV output uses the same shared Function Token parser and JSON alias registry.
            var generator = try AgentGenerator(capabilities: descriptor.capabilities, textActions: [])
            var calls = try generator.append("<showPose payload='" + AgentGenerator.escapeText(json) + "'/>")
            if let aim = nextAim(people: result.people, image: image) {
                calls += try generator.append("<aim base=\"\(aim.base)\" pitch=\"\(aim.pitch)\"/>")
                lastAim = (aim.base, aim.pitch, image.timestamp)
            }
            calls += try generator.finish()
            for call in calls { try emit(.actionCall(call), input: input) }
            try emit(.control("agent.finished"), input: input)
            processed += 1
        } catch is CancellationError {} catch {
            if !Task.isCancelled && lifecycle != .stopped {
                do { try emit(.control("agent.error: pose inference failed"), input: input) } catch {}
                lifecycle = .failed
                pending = nil
                continuation.finish()
            }
        }
    }
    /// Image-center error times 0.8 radians. Nose is the aim point when it is visible.
    private func nextAim(people: [PersonPose], image: ImageInput) -> (base: Double, pitch: Double)? {
        guard controlsArm, let person = people.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let width = Double(image.width)
        let height = Double(image.height)
        let point = aimPoint(person, width: width, height: height)
        let base = (point.x / width - 0.5) * 0.8
        let pitch = (point.y / height - 0.5) * 0.8
        if let lastAim {
            let waited = image.timestamp - lastAim.time >= 0.2
            let moved = hypot(base - lastAim.base, pitch - lastAim.pitch) >= 0.02
            guard waited, moved else { return nil }
        }
        return (base, pitch)
    }

    private func aimPoint(_ person: PersonPose, width: Double, height: Double) -> (x: Double, y: Double) {
        if let nose = person.keypoints.first(where: { $0.joint == .nose }),
            nose.confidence >= 0.3, nose.x.isFinite, nose.y.isFinite,
            Double(nose.x) >= 0, Double(nose.y) >= 0, Double(nose.x) <= width, Double(nose.y) <= height
        {
            return (Double(nose.x), Double(nose.y))
        }
        return (Double(person.box.x + person.box.width / 2), Double(person.box.y + person.box.height / 2))
    }

    private func emit(_ output: AgentOutput, input: AgentInput) throws {
        switch continuation.yield(OutputEnvelope(source: descriptor.id, input: input, output: output)) {
        case .enqueued: return
        case .dropped, .terminated:
            lifecycle = .failed
            pending = nil
            continuation.finish()
            throw HarnessError.queueFull
        @unknown default: throw HarnessError.queueFull
        }
    }
}
