import AgentCore
import Foundation

/// Photography policy consumes shared poses and emits UI actions; no inference or raw media.
public actor PhotographerAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let sessionID: UUID
    private var lifecycle: AgentLifecycle = .registered
    public private(set) var replacements = 0
    public private(set) var expiredInputs = 0
    private var pending: AgentInput?
    private var worker: Task<Void, Never>?
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var processed = 0

    public init(
        sessionID: UUID, configuration: AgentConfiguration? = nil
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "Photographer")
        guard configuration.agentID == .photographer else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Photographer",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.actionCall, .control], capabilities: configuration.capabilities)
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
        guard case .observation(.pose(let image)) = input.payload else { throw HarnessError.unsupportedInput }
        guard lastSequence.map({ image.sequence > $0 }) ?? true,
            lastTimestamp.map({ image.timestamp >= $0 }) ?? true
        else { throw ImageInputError.outOfOrder }
        try image.validate()
        guard !input.metadata.expired else { throw CommunicationError.expired }
        lastSequence = image.sequence
        lastTimestamp = image.timestamp
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
            guard case .observation(.pose(let image)) = input.payload else { throw HarnessError.unsupportedInput }
            guard !input.metadata.expired else {
                expiredInputs += 1
                return
            }
            let people = try image.people.prefix(6).map { person in
                guard person.count == 17 else { throw CommunicationError.invalidPayload }
                return try person.enumerated().map { index, point in
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
                do { try emit(.control("agent.error: pose presentation failed"), input: input) } catch {}
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
