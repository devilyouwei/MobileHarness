import AgentCore
import Foundation
import ModelKit
import PlatformKit

/// Shared visual perception: one model operation and one newest pending frame, publishes shared observations, skeleton visualization and face-driven gaze Tools.
public actor VisionPerceptionAgent: Agent {
    private static let gaze = InternalTool(path: "UI.Gaze.moveEyes", required: ["x", "y"])
    private static let overlay = InternalTool(path: "UI.Pose.showPose", required: ["payload"])
    private var resultInbox = ActionResultInbox()
    public func actionResults() -> [ActionResult] { resultInbox.results }
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private var port: AgentMessaging?
    private var cadence: FrameCadence
    private var gaze: FaceGazeTracker
    public private(set) var gazeReplacements = 0
    public private(set) var replacements = 0
    public private(set) var expiredInputs = 0
    private let pose: any PoseCapability
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
    public private(set) var publicationRejections = 0
    public private(set) var overlayReplacements = 0
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var processed = 0
    private var fpsWindow: ContinuousClock.Instant?
    private var fpsCompletions = 0
    private var framesPerSecond: Double?

    public init(
        pose: any PoseCapability, sessionID: UUID, configuration: AgentConfiguration? = nil,
        sampling: FrameSamplingConfiguration? = nil, mirroredGaze: Bool = false
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "VisionPerception")
        guard configuration.agentID == .visionPerception else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "VisionPerception",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.toolCall, .control],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        self.cadence = FrameCadence(configuration: try sampling ?? FrameSamplingConfiguration())
        self.gaze = FaceGazeTracker(mirrored: mirroredGaze)
        self.pose = pose
        self.sessionID = sessionID
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(2))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(internalTools: [gaze, overlay])
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
        guard input.sessionID == sessionID else { throw CommunicationError.scopeClosed }
        guard !input.metadata.expired else {
            expiredInputs += 1
            throw CommunicationError.expired
        }
        if case .actionResult(let result) = input.payload {
            guard input.metadata.source == "runtime", result.owner.agent == descriptor.id,
                result.owner.sessionID == input.sessionID
            else { throw CommunicationError.unauthorized }
            resultInbox.accept(result)
            return
        }
        guard case .image(let image) = input.payload else { throw HarnessError.unsupportedInput }
        guard lastSequence.map({ image.sequence > $0 }) ?? true,
            lastTimestamp.map({ image.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        lastSequence = image.sequence
        lastTimestamp = image.timestamp
        if pending != nil { replacements += 1 }
        pending = input  // Every valid capture replaces the slot, regardless of motion or cadence.
        drain()
    }
    private func drain() {
        guard lifecycle == .running, worker == nil, pending != nil else { return }
        worker = Task { await inferLatest() }
    }
    private func inferLatest() async {
        guard lifecycle == .running, let input = pending else {
            worker = nil
            return
        }
        pending = nil
        await infer(input)
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
            let staleBefore = cadence.staleInputs
            guard try cadence.accepts(image, at: image.capturedAt == nil ? nil : .now) else {
                expiredInputs += cadence.staleInputs - staleBefore
                return
            }
            let context = InferenceContext(requestID: input.id, conversationID: input.sessionID)
            let resolved = try Self.resolveImage(image)
            guard resolved.width == image.width, resolved.height == image.height else {
                throw ImageInputError.invalidFrame
            }
            let startedAt = ContinuousClock.now
            if fpsWindow == nil { fpsWindow = startedAt }
            let result = try await pose.estimatePose(
                PoseRequest(
                    image: resolved, context: context))
            let finishedAt = ContinuousClock.now
            try Task.checkCancellation()
            guard lifecycle == .running || lifecycle == .paused else { return }
            guard result.context == context else {
                throw CapabilityError.invalidRequest("Pose result context mismatch")
            }
            let inferenceDuration = Self.milliseconds(startedAt.duration(to: finishedAt)) / 1000
            let totalLatency = image.capturedAt.map { Self.milliseconds($0.duration(to: finishedAt)) / 1000 }
            guard !input.metadata.expired, totalLatency.map({ $0 < cadence.maximumObservationLatency }) ?? true else {
                try cadence.observeTiming(inferenceDuration: inferenceDuration, totalLatency: totalLatency)
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
            try cadence.observe(observation, inferenceDuration: inferenceDuration, totalLatency: totalLatency)
            fpsCompletions += 1
            if let fpsWindow {
                let elapsed = Self.milliseconds(fpsWindow.duration(to: finishedAt)) / 1000
                if elapsed >= 1 {
                    framesPerSecond = Double(fpsCompletions) / elapsed
                    self.fpsWindow = finishedAt
                    fpsCompletions = 0
                }
            }
            let statistics = PoseOverlayPayload.Statistics(
                queueMilliseconds: image.capturedAt.map { Self.milliseconds($0.duration(to: startedAt)) },
                inferenceMilliseconds: Self.milliseconds(startedAt.duration(to: finishedAt)),
                totalMilliseconds: image.capturedAt.map { Self.milliseconds($0.duration(to: finishedAt)) },
                framesPerSecond: framesPerSecond, replacements: replacements,
                detectionIntervalMilliseconds: cadence.interval * 1000, imageMotion: cadence.imageActivity)
            try emitOverlay(observation, input: input, statistics: statistics)
            let target = gaze.update(observation)
            let move = try Self.gaze.call(["x": String(target.x), "y": String(target.y)])
            try emit(.toolCall(move), input: input)
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
                let report = try await port.publishResult(.pose(publication.observation), parent: publication.parent)
                try Task.checkCancellation()
                // Optional subscribers own their admission failures; local perception/display continues.
                publicationRejections += max(report.rejected.count, report.failure == nil ? 0 : 1)
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
    private static func resolveImage(_ input: ImageInput) throws -> ImageFrame {
        switch input.content {
        case .rgb(let rgb): return try ImageFrame(width: input.width, height: input.height, rgb: rgb)
        case .attachment(let attachment):
            guard let sample = attachment as? SampledImageAttachment,
                let camera = sample.source as? CameraImageAttachment,
                camera.frame.width == input.width, camera.frame.height == input.height,
                camera.frame.rotation == input.rotation,
                camera.frame.sequence == input.sequence, camera.frame.timestamp == input.timestamp,
                camera.frame.capturedAt == input.capturedAt, camera.frame.gray64 == sample.gray64
            else { throw ImageInputError.invalidFrame }
            return try camera.frame.withPixelBuffer { try ImageFrame(pixelBuffer: $0, rotation: input.rotation) }
        }
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return max(0, Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
    private func emitOverlay(
        _ image: PoseObservation, input: AgentInput, statistics: PoseOverlayPayload.Statistics
    ) throws {
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
                return PoseOverlayPayload.Joint(
                    x: Int((max(-1, min(2, x)) * 10000).rounded()),
                    y: Int((max(-1, min(2, y)) * 10000).rounded()),
                    confidence: visible ? Int((point.confidence * 1000).rounded()) : 0)
            }
        }
        let overlay = PoseOverlayPayload(
            sequence: image.sequence, timestamp: image.timestamp, rotation: image.rotation, people: people,
            statistics: statistics)
        let data = try JSONEncoder().encode(overlay)
        guard data.count <= 3000, let json = String(data: data, encoding: .utf8) else {
            throw CommunicationError.invalidPayload
        }
        let call = try Self.overlay.call(["payload": json])
        try emit(.toolCall(call), input: input)
    }
    private func emit(_ output: AgentOutput, input: AgentInput) throws {
        guard case .image(let image) = input.payload else { throw HarnessError.unsupportedInput }
        switch continuation.yield(
            OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: image.sequence))
        {
        case .enqueued: return
        case .dropped(let replaced):
            // Only this Agent's replaceable UI state may be coalesced; never arbitrary device commands.
            switch replaced.output {
            case .toolCall(let call) where call.toolPath == "UI.Pose.showPose": overlayReplacements += 1
            case .toolCall(let call) where call.toolPath == "UI.Gaze.moveEyes":
                gazeReplacements += 1
            default: throw HarnessError.queueFull
            }
        case .terminated: throw CancellationError()
        @unknown default: throw HarnessError.queueFull
        }
    }
}

/// Agent transport retains the unconverted device output; only the inference worker constructs ModelKit input.
public struct CameraImageAttachment: ImageAttachment {
    public let frame: CameraFrame
    public init(frame: CameraFrame) { self.frame = frame }
}
