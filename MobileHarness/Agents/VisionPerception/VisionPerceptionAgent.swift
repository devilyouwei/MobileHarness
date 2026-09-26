import AgentCore
import Foundation
import ModelKit

/// Shared visual perception: one model operation and one newest pending frame, no display policy.
public actor VisionPerceptionAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private var port: AgentMessaging?
    private var filter: FrameChangeFilter
    public private(set) var replacements = 0
    public private(set) var expiredInputs = 0
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
        sampling: FrameChangeConfiguration? = nil,
        resolveImage: @escaping @Sendable (ImageInput) throws -> ImageFrame = { input in
            guard case .rgb(let rgb) = input.content else { throw ImageInputError.invalidFrame }
            return try ImageFrame(width: input.width, height: input.height, rgb: rgb)
        }
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "VisionPerception")
        guard configuration.agentID == .visionPerception else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "VisionPerception", inputs: [.image],
            outputs: [.control], capabilities: configuration.capabilities)
        self.filter = FrameChangeFilter(configuration: try sampling ?? FrameChangeConfiguration())
        self.pose = pose
        self.resolveImage = resolveImage
        self.sessionID = sessionID
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public func bind(_ port: AgentMessaging) throws {
        guard lifecycle == .registered, self.port == nil else { throw HarnessError.invalidTransition }
        self.port = port
    }
    public func start() throws {
        guard lifecycle == .registered, port != nil else { throw HarnessError.invalidTransition }
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
        guard !input.metadata.expired else {
            expiredInputs += 1
            throw CommunicationError.expired
        }
        lastSequence = image.sequence
        lastTimestamp = image.timestamp
        guard try filter.accepts(image) else { return }
        if pending != nil { replacements += 1 }
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
            guard !input.metadata.expired else {
                expiredInputs += 1
                return
            }
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
            guard !input.metadata.expired else {
                expiredInputs += 1
                return
            }
            let people = try result.people.map { person in
                guard person.keypoints.count == 17 else { throw CommunicationError.invalidPayload }
                return try person.keypoints.enumerated().map { index, point in
                    guard point.joint.rawValue == index else { throw CommunicationError.invalidPayload }
                    return PoseObservation.Joint(x: point.x, y: point.y, confidence: point.confidence)
                }
            }
            let observation = try PoseObservation(
                width: image.width, height: image.height, sequence: image.sequence,
                timestamp: image.timestamp, rotation: image.rotation, people: people)
            guard let port else { throw CommunicationError.unauthorized }
            let report = try await port.publish(.pose(observation), parent: input)
            guard report.rejected.values.allSatisfy({ $0 == "superseded" || $0 == "expired" }) else {
                throw CommunicationError.unavailableTarget
            }
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
