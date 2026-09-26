import AgentCore
import Foundation
import ModelKit

/// Shared visual perception: one model operation and one newest pending frame, publishes shared observations and invokes the skeleton visualization Tool.
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
    private struct Publication: Sendable {
        let observation: PoseObservation
        let parent: AgentInput
    }
    private var pendingPublication: Publication?
    private var publisher: Task<Void, Never>?
    public private(set) var publicationReplacements = 0
    public private(set) var overlayReplacements = 0
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
            id: configuration.agentID, name: "VisionPerception",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.toolCall, .control], capabilities: configuration.capabilities)
        self.filter = FrameChangeFilter(configuration: try sampling ?? FrameChangeConfiguration())
        self.pose = pose
        self.resolveImage = resolveImage
        self.sessionID = sessionID
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(1))
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
        drainPublication()
    }
    public func stop() async {
        lifecycle = .stopped
        pending = nil
        pendingPublication = nil
        let inference = worker
        let publication = publisher
        inference?.cancel()
        publication?.cancel()
        await inference?.value
        await publication?.value
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
        pending = input  // Latest raw frame; display replacement has its own explicit state-only policy.
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
            try emitOverlay(observation, input: input)
            if pendingPublication != nil { publicationReplacements += 1 }
            pendingPublication = Publication(observation: observation, parent: input)
            drainPublication()
            processed += 1
        } catch is CancellationError {} catch {
            fail(input)
        }
    }
    private func drainPublication() {
        guard lifecycle == .running, publisher == nil, pendingPublication != nil else { return }
        publisher = Task { await publishLatest() }
    }
    private func publishLatest() async {
        defer { publisher = nil }
        while lifecycle == .running, let publication = pendingPublication {
            pendingPublication = nil
            if publication.parent.metadata.expired { continue }
            do {
                try Task.checkCancellation()
                guard let port else { throw CommunicationError.unauthorized }
                let report = try await port.publish(.pose(publication.observation), parent: publication.parent)
                try Task.checkCancellation()
                guard report.rejected.values.allSatisfy({ $0 == "superseded" || $0 == "expired" }) else {
                    throw CommunicationError.unavailableTarget
                }
            } catch CommunicationError.noRecipients {
                // Optional business subscribers do not gate local visualization.
            } catch is CancellationError {
                return
            } catch {
                fail(publication.parent)
                return
            }
        }
    }
    private func fail(_ input: AgentInput) {
        guard lifecycle != .stopped, lifecycle != .failed else { return }
        lifecycle = .failed
        pending = nil
        pendingPublication = nil
        worker?.cancel()
        publisher?.cancel()
        // Terminal control replaces only an unconsumed display state; no later state is admitted.
        _ = continuation.yield(
            OutputEnvelope(
                source: descriptor.id, input: input, output: .control("agent.error: pose processing failed")))
        continuation.finish()
    }
    private func emitOverlay(_ image: PoseObservation, input: AgentInput) throws {
        let people = try image.people.prefix(6).map { person in
            guard person.count == 17 else { throw CommunicationError.invalidPayload }
            return try person.map { point in
                guard point.x.isFinite, point.y.isFinite,
                    point.confidence.isFinite, (0...1).contains(point.confidence)
                else { throw CommunicationError.invalidPayload }
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
            throw CommunicationError.invalidPayload
        }
        let call = try descriptor.capabilities.resolveTool("showPose", arguments: ["payload": json])
        try emit(.toolCall(call), input: input)
    }
    private func emit(_ output: AgentOutput, input: AgentInput) throws {
        switch continuation.yield(OutputEnvelope(source: descriptor.id, input: input, output: output)) {
        case .enqueued: return
        case .dropped(let replaced):
            // Only this Agent's replaceable UI state may be coalesced; never arbitrary device commands.
            guard case .toolCall(let call) = replaced.output, call.toolPath == "UI.showPose" else {
                throw HarnessError.queueFull
            }
            overlayReplacements += 1
        case .terminated: throw CancellationError()
        @unknown default: throw HarnessError.queueFull
        }
    }
}
