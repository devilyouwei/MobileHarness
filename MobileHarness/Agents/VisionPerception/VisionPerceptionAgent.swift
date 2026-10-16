import AgentCore
import Foundation
import ModelKit
import PlatformKit
import StorageCore

/// Shared visual perception: one model operation and one newest pending frame, publishes shared observations, skeleton visualization and face-driven gaze Tools.
public actor VisionPerceptionAgent: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    private let contextRepository: AgentContextRepository<VisionPerceptionContextState>
    private let preprocessor = VisionPerceptionSignalPreprocessor()
    private let contextBuilder = VisionPerceptionContextBuilder()

    private static let gaze = InternalTool(path: "UI.Gaze.moveEyes", required: ["x", "y"])
    private static let overlay = InternalTool(path: "UI.Pose.showPose", required: ["payload"])
    private var resultInbox = ActionResultInbox()
    private let mailbox: AgentOutputMailbox
    private var cadence: FrameCadence
    private var gaze: FaceGazeTracker
    public private(set) var gazeReplacements = 0
    public private(set) var replacements = 0
    public private(set) var expiredInputs = 0
    private let pose: any PoseCapability
    private let sessionID: String
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

    // MARK: - Registration

    public init(
        pose: any PoseCapability, sessionID: String, configuration: AgentConfiguration? = nil,
        sampling: FrameSamplingConfiguration? = nil, mirroredGaze: Bool = false,
        context: AgentContextRepository<VisionPerceptionContextState>
    ) throws {
        self.contextRepository = context
        guard contextRepository.agentID == .visionPerception else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: "VisionPerception")
        guard configuration.agentID == .visionPerception else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "VisionPerception",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.communication, .toolCall, .control],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        self.cadence = FrameCadence(configuration: try sampling ?? FrameSamplingConfiguration())
        self.gaze = FaceGazeTracker(mirrored: mirroredGaze)
        self.pose = pose
        self.sessionID = sessionID
        let mailbox = AgentOutputMailbox(capacity: 18)
        self.mailbox = mailbox
        outputs = mailbox.stream
    }
    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(internalTools: [gaze, overlay])
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        let id = sessionID
        try await contextRepository.update { $0.state.perceptionSessionID = id }
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
        mailbox.close()
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {

        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == sessionID else { throw CommunicationError.scopeClosed }
        guard !input.metadata.expired else {
            expiredInputs += 1
            throw CommunicationError.expired
        }
        if case .actionResult(let result) = input.payload {
            guard input.metadata.origin == .runtime, input.metadata.source == "runtime",
                result.owner.agent == descriptor.id,
                result.owner.sessionID == input.sessionID
            else { throw CommunicationError.unauthorized }
            try await prepareSignal(input)
            resultInbox.accept(result)
            return
        }
        let state = try await contextRepository.snapshot().state
        _ = try preprocessor.classify(input, state: state)
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

    // MARK: - Decision workers

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
            let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
            let decision = try contextBuilder.build(state: selection, batch: selection.batch())
            let inference = try decision.inferenceRequest()
            let context = inference.context
            let startedAt = ContinuousClock.now
            if fpsWindow == nil { fpsWindow = startedAt }
            let result = try await pose.estimatePose(inference)
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
            try await contextRepository.update { $0.state.latestFrameSequence = observation.sequence }
            try Task.checkCancellation()
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
                try await communicate(.pose(publication.observation), parent: publication.parent)
                try Task.checkCancellation()
                // Optional subscribers own their admission failures; local perception/display continues.
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
        mailbox.close(
            terminal: OutputEnvelope(
                source: descriptor.id, input: input,
                output: .control("agent.error: pose processing failed")))
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return max(0, Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
    // MARK: - Output

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
        let key: String?
        if case .toolCall(let call) = output {
            switch call.toolPath {
            case "UI.Pose.showPose": key = "overlay"
            case "UI.Gaze.moveEyes": key = "gaze"
            default: key = nil
            }
        } else {
            key = nil
        }
        let replaced = try mailbox.admit(
            OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: image.sequence),
            replacing: key)
        if let replaced {
            if case .toolCall(let call) = replaced.output, call.toolPath == "UI.Pose.showPose" {
                overlayReplacements += 1
            } else {
                gazeReplacements += 1
            }
        }
    }

    // MARK: - Communication output

    private func communicate(_ message: AgentMessage, parent: AgentInput) async throws {
        let action = try CommunicationAction(message: message)
        let evidence = try JSONEncoder().encode(
            SignalEvidence(
                AgentInput(
                    id: action.id, sessionID: parent.sessionID, payload: .observation(message),
                    metadata: parent.metadata, turn: parent.turn, taskScope: parent.taskScope)))
        try await contextRepository.update {
            try $0.append(
                .init(
                    id: action.id, taskID: parent.taskScope?.id ?? parent.id,
                    kind: "communication.output", data: evidence),
                retainingLast: VisionPerceptionSignalPreprocessor.evidenceCapacity)
        }
        try emit(.communication(action), input: parent)
    }

    // MARK: - Context

    private func prepareSignal(_ input: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if case .replaceLatest = disposition { return }
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback, retainingLast: VisionPerceptionSignalPreprocessor.evidenceCapacity)
    }

    // MARK: - Observability

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: pending == nil ? 0 : 1, processedInputs: processed)
    }

    public func contextSnapshot() async throws -> AgentContext<VisionPerceptionContextState> {
        try await contextRepository.snapshot()
    }
    public func actionResults() -> [ActionResult] { resultInbox.results }
}

/// Agent transport retains the unconverted device output; only the inference worker constructs ModelKit input.
public struct CameraImageAttachment: ImageAttachment {
    public let frame: CameraFrame
    public init(frame: CameraFrame) { self.frame = frame }
}
