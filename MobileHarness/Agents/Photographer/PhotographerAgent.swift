import AgentCore
import Foundation
import ModelKit

/// Photography/motion role, phase one: pose perception and UI actions only; no robot commands.
public actor PhotographerAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let pose: any PoseCapability
    private let resolveImage: @Sendable (ImageInput) throws -> ImageFrame
    private let sessionID: UUID
    private var lifecycle: AgentLifecycle = .registered
    private var pending: AgentInput?
    private var worker: Task<Void, Never>?
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var processed = 0

    public init(
        pose: any PoseCapability, sessionID: UUID, configuration: AgentConfiguration? = nil,
        resolveImage: @escaping @Sendable (ImageInput) throws -> ImageFrame = { input in
            guard case .rgb(let rgb) = input.content else { throw ImageInputError.invalidFrame }
            return try ImageFrame(width: input.width, height: input.height, rgb: rgb)
        }
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Photographer")
        guard configuration.agentID == .photographer else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Photographer", inputs: [.image],
            outputs: [.actionCall, .control], capabilities: configuration.capabilities)
        self.pose = pose
        self.resolveImage = resolveImage
        self.sessionID = sessionID
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
            let resolved = try resolveImage(image)
            guard resolved.width == image.width, resolved.height == image.height else {
                throw ImageInputError.invalidFrame
            }
            let result = try await pose.estimatePose(
                PoseRequest(
                    image: resolved, context: context))
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
            let calls =
                try generator.append("<showPose payload='" + AgentGenerator.escapeText(json) + "'/>")
                + generator.finish()
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
