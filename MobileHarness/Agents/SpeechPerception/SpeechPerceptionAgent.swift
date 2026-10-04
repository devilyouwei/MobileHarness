import AgentCore
import Foundation
import ModelKit
import PlatformKit

/// Streaming perception only. Device capture and playback remain composition-owned.
public actor SpeechPerceptionAgent: Agent {
    private static let transcript = InternalTool(path: "UI.setTranscript", required: ["text"])
    private static let voiceState = InternalTool(path: "UI.setVoiceState", required: ["state"])
    private static let finishTranscript = InternalTool(path: "UI.finishTranscript")
    private var resultInbox = ActionResultInbox()
    public func actionResults() -> [ActionResult] { resultInbox.results }
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let recognition: any SpeechRecognitionCapability
    private let vad: any VoiceActivityCapability
    private let resampler: StreamingMonoPCMResampler
    private let sessionID: UUID
    private var port: AgentMessaging?
    private var segmenter: VoiceActivitySegmenter?
    private var recognitionTurn: SpeechRecognitionTurn?
    private var lifecycle: AgentLifecycle = .registered
    private var queue: [AgentInput] = []
    private var queuedSamples = 0
    private var worker: Task<Void, Never>?
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?
    private var processed = 0
    private var awaitingReply = false
    private var activeInput: AgentInput?
    private var currentTurn: AgentTurn?
    private var turnOrdinal: UInt64 = 0
    private var outputSequence: UInt64 = 0
    private var phase: SpeechPhase = .listening

    public init(
        recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
        sessionID: UUID, configuration: AgentConfiguration? = nil
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "SpeechPerception")
        guard configuration.agentID == .speechPerception else { throw AgentConfigurationError.identityMismatch }
        self.resampler = try StreamingMonoPCMResampler(outputSampleRate: 16000)
        self.recognition = recognition
        self.vad = vad
        self.sessionID = sessionID
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Speech Perception",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.toolCall, .control],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(32))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(internalTools: [transcript, voiceState, finishTranscript])
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
        prepareRecognitionTurn()
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
        guard let activeInput else { throw HarnessError.invalidTransition }
        try await resetListening(after: activeInput)
        try await transition(to: .listening, input: activeInput, publish: false)
    }
    public func stop() async {
        lifecycle = .stopped
        clearPendingAudio()
        worker?.cancel()
        await recognitionTurn?.cancel()
        await segmenter?.cancel()
        await worker?.value
        recognitionTurn = nil
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
        if case .actionResult(let result) = input.payload {
            guard input.metadata.source == "runtime", result.owner.agent == descriptor.id,
                result.owner.sessionID == input.sessionID
            else { throw CommunicationError.unauthorized }
            resultInbox.accept(result)
            return
        }
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
    private func prepareRecognitionTurn() {
        currentTurn = nil
        recognitionTurn = SpeechRecognitionTurn(recognition: recognition, sessionID: sessionID) { [weak self] text in
            guard let self else { throw CancellationError() }
            try await self.preview(text)
        }
    }
    private func preview(_ text: String) async throws {
        guard lifecycle == .running || lifecycle == .paused, let parent = activeInput, let port else {
            throw CancellationError()
        }
        _ = try await port.publishResult(.transcript(text, final: false), parent: parent)
        try presentTranscript(text, input: parent)
    }
    private func presentTranscript(_ text: String, input: AgentInput) throws {
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw CancellationError() }
        // Presentation is bounded separately from the complete shared transcription.
        let call = try Self.transcript.call(["text": String(text.suffix(320))])
        try emit(.toolCall(call), input: input)
        // Close output bookkeeping after this immediate display update completes.
        try emit(.control("agent.finished"), input: input)
    }
    private func presentPhase(_ phase: SpeechPhase, input: AgentInput) throws {
        let state = phase == .processing ? "processing" : phase == .speaking ? "hearing" : "listening"
        let call = try Self.voiceState.call(["state": state])
        try emit(.toolCall(call), input: input)
        try emit(.control("agent.finished"), input: input)
    }
    /// Owns phase state, presentation and optional observation as one explicit transition.
    private func transition(to next: SpeechPhase, input: AgentInput, publish: Bool = true) async throws {
        // Empty is a published outcome, not a persistent capture mode.
        phase = next == .empty ? .listening : next
        try presentPhase(next, input: input)
        if publish, let port { _ = try await port.publishResult(.speechPhase(next), parent: input) }
    }
    private func resetListening(after input: AgentInput) async throws {
        await resampler.reset()
        try await segmenter?.reset()
        prepareRecognitionTurn()
        awaitingReply = false
        activeInput = input
    }
    private func clearPendingAudio() {
        queue.removeAll()
        queuedSamples = 0
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
                try await processAudio(queue.removeFirst())
            }
        } catch is CancellationError {} catch {
            guard lifecycle != .stopped else { return }
            await fail(error)
        }
    }
    private func processAudio(_ acceptedInput: AgentInput) async throws {
        let input = acceptedInput
        guard case .audio(let audio) = input.payload, let segmenter, let recognitionTurn, let port else {
            throw HarnessError.unsupportedInput
        }
        queuedSamples -= audio.sampleCount
        guard !input.metadata.expired else { throw CommunicationError.expired }
        let samples = audio.samples.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        var timestamp = audio.timestamp
        for offset in stride(from: 0, to: samples.count, by: 8192) {
            let packets = try await resampler.process(
                MicrophoneFrame(
                    samples: Array(samples[offset..<min(offset + 8192, samples.count)]),
                    sampleRate: audio.sampleRate, sequence: audio.sequence))
            for packet in packets {
                guard !awaitingReply else { break }
                let frame = try AudioFrame(
                    data: packet.samples.withUnsafeBytes { Data($0) },
                    format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32),
                    sequence: packet.sequence, timestamp: timestamp)
                try await processFrame(
                    frame, input: input, segmenter: segmenter, recognitionTurn: recognitionTurn, port: port)
                timestamp += packet.duration
            }
        }
    }
    private func processFrame(
        _ frame: AudioFrame, input acceptedInput: AgentInput, segmenter: VoiceActivitySegmenter,
        recognitionTurn: SpeechRecognitionTurn, port: AgentMessaging
    ) async throws {
        var input = acceptedInput
        activeInput = AgentInput(
            id: input.id, sessionID: input.sessionID, payload: input.payload,
            metadata: input.metadata, turn: currentTurn)
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
            currentTurn = AgentTurn(ordinal: turnOrdinal)
        }
        input = AgentInput(
            id: input.id, sessionID: input.sessionID, payload: input.payload,
            metadata: input.metadata, turn: currentTurn)
        activeInput = input
        if beganTurn && !result.isSpeaking {
            try await transition(to: .speaking, input: input)
        }
        let newPhase: SpeechPhase = result.isSpeaking ? .speaking : .listening
        if phase != newPhase {
            try await transition(to: newPhase, input: input)
        }
        var events: [VoiceStreamEvent] = []
        for event in result.streamEvents {
            events.append(event)
            if case .end(let reason) = event, reason != .maximumDuration { break }
        }
        try await recognitionTurn.enqueue(events)
        processed += 1
        if events.contains(where: {
            if case .end(let reason) = $0 { return reason != .maximumDuration }
            return false
        }) {
            try await finishUtterance(input: input, recognitionTurn: recognitionTurn, port: port)
        }
    }
    private func finishUtterance(
        input: AgentInput, recognitionTurn: SpeechRecognitionTurn, port: AgentMessaging
    ) async throws {
        awaitingReply = true
        // Buffered post-endpoint audio belongs to the explicitly suppressed reply interval.
        clearPendingAudio()
        try await transition(to: .processing, input: input)
        let text = try await recognitionTurn.finish()
        try Task.checkCancellation()
        try emit(.toolCall(Self.finishTranscript.call([:])), input: input)
        try emit(.control("agent.finished"), input: input)
        if text.isEmpty {
            try await resetListening(after: input)
            try await transition(to: .empty, input: input)
            return
        }
        let report = try await port.publishResult(.transcript(text, final: true), parent: input)
        if report.delivered.isEmpty || !report.rejected.isEmpty || report.failure != nil {
            try await resetListening(after: input)
            // Preserve the existing delivery recovery contract: local presentation only.
            try await transition(to: .empty, input: input, publish: false)
        }
    }
    private func fail(_ error: any Error) async {
        lifecycle = .failed
        clearPendingAudio()
        await recognitionTurn?.cancel()
        await segmenter?.cancel()
        if let activeInput {
            // Best effort: overflow may prevent the failure control from being enqueued.
            outputSequence += 1
            continuation.yield(
                OutputEnvelope(
                    source: descriptor.id, input: activeInput,
                    output: .control("agent.error: speech perception failed: \(error)"), sequence: outputSequence))
        }
        continuation.finish()
    }

}
