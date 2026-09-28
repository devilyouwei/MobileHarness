import AgentCore
import Foundation
import ModelKit

/// Streaming perception only. Device capture and playback remain composition-owned.
public actor SpeechPerceptionAgent: Agent {
    private static let transcript = InternalAction(
        module: "UI", function: "setTranscript", channel: "Transcript", required: ["text"])
    private static let voiceState = InternalAction(
        module: "UI", function: "setVoiceState", channel: "Display", required: ["state"])
    private static let finishTranscript = InternalAction(
        module: "UI", function: "finishTranscript", channel: "Transcript")
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let recognition: any SpeechRecognitionCapability
    private let vad: any VoiceActivityCapability
    private let sessionID: UUID
    private var port: AgentMessaging?
    private var segmenter: VoiceActivitySegmenter?
    private var turn: LiveSpeechInput?
    private var lifecycle: AgentLifecycle = .registered
    private var queue: [AgentInput] = []
    private var queuedSamples = 0
    private var worker: Task<Void, Never>?
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var processed = 0
    private var awaitingReply = false
    private var activeInput: AgentInput?
    private var currentTurn: ConversationTurn?
    private var turnOrdinal: UInt64 = 0
    private var outputSequence: UInt64 = 0
    private var phase: SpeechPhase = .listening

    public init(
        recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
        sessionID: UUID, configuration: AgentConfiguration? = nil
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "SpeechPerception")
        guard configuration.agentID == .speechPerception else { throw AgentConfigurationError.identityMismatch }
        self.recognition = recognition
        self.vad = vad
        self.sessionID = sessionID
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Speech Perception",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.actionCall, .control],
            capabilities: try configuration.capabilities.adding(internalActions: [
                Self.transcript, Self.voiceState, Self.finishTranscript,
            ]))
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(32))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public func bind(_ port: AgentMessaging) throws {
        guard lifecycle == .registered, self.port == nil else { throw HarnessError.invalidTransition }
        self.port = port
    }
    public func start() async throws {
        guard lifecycle == .registered, port != nil else { throw HarnessError.invalidTransition }
        let session = try await vad.detectVoiceActivity(
            format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32))
        guard lifecycle == .registered, !Task.isCancelled else {
            await session.cancel()
            throw CancellationError()
        }
        segmenter = VoiceActivitySegmenter(session: session)
        lifecycle = .running
        makeTurn()
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
    /// Runtime flow control, independent of a full audio inbox.
    public func resumeListening() async throws {
        guard lifecycle == .running, awaitingReply else { return }
        // Wait for final publication to finish before resetting its ASR/VAD state.
        await worker?.value
        guard lifecycle == .running else { throw HarnessError.notRunning }
        try await segmenter?.reset()
        makeTurn()
        awaitingReply = false
        phase = .listening
        if let activeInput { try presentPhase(.listening, input: activeInput) }
    }
    public func stop() async {
        lifecycle = .stopped
        queue.removeAll()
        queuedSamples = 0
        worker?.cancel()
        await turn?.cancel()
        await segmenter?.cancel()
        await worker?.value
        turn = nil
        segmenter = nil
        activeInput = nil
        continuation.finish()
    }
    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: queue.count, processedInputs: processed)
    }
    public func receive(_ input: AgentInput) throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == sessionID else { throw CommunicationError.scopeClosed }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard case .audio(let audio) = input.payload else { throw HarnessError.unsupportedInput }
        // Capture is deliberately gated while recognizing/replying; no new utterance is admitted.
        guard !awaitingReply else { throw CapabilityError.inputBusy }
        guard lastSequence.map({ audio.sequence > $0 }) ?? true,
            lastTimestamp.map({ audio.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        guard queue.count < 128, queuedSamples + audio.sampleCount <= 64_000 else { throw HarnessError.queueFull }
        lastSequence = audio.sequence
        lastTimestamp = audio.timestamp
        queue.append(input)
        queuedSamples += audio.sampleCount
        drain()
    }
    private func makeTurn() {
        currentTurn = nil
        turn = LiveSpeechInput(recognition: recognition, sessionID: sessionID) { [weak self] text in
            guard let self else { throw CancellationError() }
            try await self.preview(text)
        }
    }
    private func preview(_ text: String) async throws {
        guard lifecycle == .running || lifecycle == .paused, let parent = activeInput, let port else {
            throw CancellationError()
        }
        _ = try await port.publish(.transcript(text, final: false), parent: parent)
        try presentTranscript(text, input: parent)
    }
    private func presentTranscript(_ text: String, input: AgentInput) throws {
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw CancellationError() }
        // Presentation is bounded separately from the complete shared transcription.
        let call = try Self.transcript.call(["text": String(text.suffix(320))])
        try emit(.actionCall(call), input: input)
        // Release scheduler input tracking after this ordered display update completes.
        try emit(.control("agent.finished"), input: input)
    }
    private func presentPhase(_ phase: SpeechPhase, input: AgentInput) throws {
        let state = phase == .processing ? "processing" : phase == .speaking ? "hearing" : "listening"
        let call = try Self.voiceState.call(["state": state])
        try emit(.actionCall(call), input: input)
        try emit(.control("agent.finished"), input: input)
    }
    private func emit(_ output: AgentOutput, input: AgentInput) throws {
        outputSequence += 1
        switch continuation.yield(
            OutputEnvelope(source: descriptor.id, input: input, output: output, sequence: outputSequence))
        {
        case .enqueued: return
        case .dropped, .terminated: throw HarnessError.queueFull
        @unknown default: throw HarnessError.queueFull
        }
    }
    private func drain() {
        guard lifecycle == .running, !awaitingReply, worker == nil, !queue.isEmpty else { return }
        worker = Task { await self.consume() }
    }
    private func consume() async {
        defer {
            worker = nil
            drain()
        }
        do {
            while lifecycle == .running, !queue.isEmpty, !awaitingReply {
                var input = queue.removeFirst()
                guard case .audio(let audio) = input.payload, let segmenter, let turn, let port else {
                    throw HarnessError.unsupportedInput
                }
                queuedSamples -= audio.sampleCount
                guard !input.metadata.expired else { throw CommunicationError.expired }
                activeInput = AgentInput(
                    id: input.id, sessionID: input.sessionID, payload: input.payload,
                    metadata: input.metadata, turn: currentTurn)
                let frame = try AudioFrame(
                    data: audio.samples, format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32),
                    sequence: audio.sequence, timestamp: audio.timestamp)
                let result = try await segmenter.process(frame)
                try Task.checkCancellation()
                let beganTurn =
                    currentTurn == nil
                    && (result.isSpeaking
                        || result.streamEvents.contains {
                            if case .audio = $0 { return true }
                            return false
                        })
                if beganTurn {
                    turnOrdinal += 1
                    currentTurn = ConversationTurn(ordinal: turnOrdinal)
                }
                input = AgentInput(
                    id: input.id, sessionID: input.sessionID, payload: input.payload,
                    metadata: input.metadata, turn: currentTurn)
                activeInput = input
                if beganTurn && !result.isSpeaking {
                    try presentPhase(.speaking, input: input)
                    _ = try await port.publish(.speechPhase(.speaking), parent: input)
                }
                let newPhase: SpeechPhase = result.isSpeaking ? .speaking : .listening
                if phase != newPhase {
                    phase = newPhase
                    try presentPhase(phase, input: input)
                    _ = try await port.publish(.speechPhase(phase), parent: input)
                }
                var events: [VoiceStreamEvent] = []
                for event in result.streamEvents {
                    events.append(event)
                    if case .end(let reason) = event, reason != .maximumDuration { break }
                }
                try await turn.enqueue(events)
                processed += 1
                if events.contains(where: {
                    if case .end(let reason) = $0 { return reason != .maximumDuration }
                    return false
                }) {
                    awaitingReply = true
                    // Already buffered capture after the endpoint belongs to the suppressed reply interval.
                    queue.removeAll()
                    queuedSamples = 0
                    try presentPhase(.processing, input: input)
                    _ = try await port.publish(.speechPhase(.processing), parent: input)
                    let text = try await turn.finish()
                    try Task.checkCancellation()
                    let close = try Self.finishTranscript.call()
                    try emit(.actionCall(close), input: input)
                    try emit(.control("agent.finished"), input: input)
                    if text.isEmpty {
                        try await segmenter.reset()
                        makeTurn()
                        awaitingReply = false
                        phase = .listening
                        try presentPhase(.empty, input: input)
                        _ = try await port.publish(.speechPhase(.empty), parent: input)
                    } else {
                        let report = try await port.publish(.transcript(text, final: true), parent: input)
                        guard !report.delivered.isEmpty, report.rejected.isEmpty else {
                            throw CommunicationError.unavailableTarget
                        }
                    }
                }
            }
        } catch is CancellationError {} catch {
            guard lifecycle != .stopped else { return }
            lifecycle = .failed
            queue.removeAll()
            queuedSamples = 0
            await turn?.cancel()
            await segmenter?.cancel()
            if let activeInput {
                continuation.yield(
                    OutputEnvelope(
                        source: descriptor.id, input: activeInput,
                        output: .control("agent.error: speech perception failed: \(error)")))
            }
            continuation.finish()
        }
    }
}
