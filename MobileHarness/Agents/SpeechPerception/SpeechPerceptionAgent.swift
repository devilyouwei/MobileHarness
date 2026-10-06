import AgentCore
import Foundation
import ModelKit
import PlatformKit

/// Streaming perception only. Device capture and playback remain composition-owned.
public actor SpeechPerceptionAgent: Agent {
    /// Host-selected diagnostic scope; model capabilities/permissions remain in the versioned configuration.
    public enum Mode: Sendable { case speechAndSoundSource, soundSourceOnly }
    private let mode: Mode
    private static let transcript = InternalTool(path: "UI.Caption.setTranscript", required: ["text"])
    private static let voiceState = InternalTool(path: "UI.VoiceState.setVoiceState", required: ["state"])
    private static let finishTranscript = InternalTool(path: "UI.Caption.finishTranscript")
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
    private var soundEstimator = SoundSourceEstimator()
    private var soundLayout: AudioChannelLayout?
    private var soundRate: Int?
    private var pendingSound: (value: SoundSourceObservation, parent: AgentInput, capturedAt: ContinuousClock.Instant)?
    private var soundPublisher: Task<Void, Never>?
    public private(set) var soundPublicationRejections = 0
    public private(set) var soundPublicationReplacements = 0

    public init(
        recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
        sessionID: UUID, configuration: AgentConfiguration? = nil, mode: Mode = .speechAndSoundSource
    ) throws {
        let configuration = try configuration ?? AgentConfigurations.load(named: "SpeechPerception")
        guard configuration.agentID == .speechPerception else { throw AgentConfigurationError.identityMismatch }
        self.resampler = try StreamingMonoPCMResampler(outputSampleRate: 16000)
        self.recognition = recognition
        self.vad = vad
        self.sessionID = sessionID
        self.mode = mode
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Speech Perception",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: mode == .speechAndSoundSource ? [.toolCall, .control] : [.control],
            capabilities: try mode == .speechAndSoundSource
                ? Self.runtimeCapabilities(configuration.capabilities) : configuration.capabilities)
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
        if mode == .soundSourceOnly {
            try Task.checkCancellation()
            lifecycle = .running
            return
        }
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
        pendingSound = nil
        soundPublisher?.cancel()
        soundEstimator.reset()
    }
    public func resume() throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        lifecycle = .running
        soundLayout = nil
        soundRate = nil
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
        soundPublisher?.cancel()
        await soundPublisher?.value
        pendingSound = nil
        soundEstimator.reset()
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
        soundEstimator.reset()
        soundLayout = nil
        soundRate = nil
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
        guard case .audio(let audio) = input.payload, let port else {
            throw HarnessError.unsupportedInput
        }
        queuedSamples -= audio.sampleCount
        guard !input.metadata.expired else { throw CommunicationError.expired }
        let samples = audio.samples.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        try Task.checkCancellation()
        if mode == .soundSourceOnly { activeInput = input }
        if soundLayout != audio.layout || soundRate != audio.sampleRate {
            soundEstimator.reset()
            await resampler.reset()
            soundLayout = audio.layout
            soundRate = audio.sampleRate
            if audio.layout == .mono {
                enqueueSound(
                    .init(state: .unavailable, timestamp: audio.timestamp, duration: 0), parent: input,
                    capturedAt: audio.capturedAt)
            }
        }
        // Spatial DSP is independent of the speech detector and uses native-rate channels.
        if audio.layout == .firstOrderAmbisonicsACNSN3D {
            for index in stride(from: 0, to: samples.count, by: 4) {
                if let value = try soundEstimator.consume(
                    w: samples[index], y: samples[index + 1], z: samples[index + 2], x: samples[index + 3],
                    sampleRate: audio.sampleRate,
                    timestamp: audio.timestamp + Double(index / 4) / Double(audio.sampleRate)
                ) {
                    let captureOffset = value.timestamp + value.duration - audio.timestamp
                    enqueueSound(
                        value, parent: input, capturedAt: audio.capturedAt.advanced(by: .seconds(captureOffset)))
                }
            }
        }
        if mode == .soundSourceOnly {
            processed += 1
            return
        }
        guard let segmenter, let recognitionTurn else { throw HarnessError.invalidTransition }
        let mono = audio.layout == .mono ? samples : stride(from: 0, to: samples.count, by: 4).map { samples[$0] }
        var timestamp = audio.timestamp
        for offset in stride(from: 0, to: mono.count, by: 8192) {
            let packets = try await resampler.process(
                MicrophoneFrame(
                    samples: Array(mono[offset..<min(offset + 8192, mono.count)]),
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
        soundEstimator.reset()
        if soundLayout == .firstOrderAmbisonicsACNSN3D, case .audio(let audio) = input.payload {
            enqueueSound(
                .init(state: .inactive, timestamp: audio.timestamp, duration: 0), parent: input,
                capturedAt: audio.capturedAt)
        }
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
        pendingSound = nil
        soundPublisher?.cancel()
        await soundPublisher?.value
        soundEstimator.reset()
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

    private func enqueueSound(
        _ value: SoundSourceObservation, parent: AgentInput, capturedAt: ContinuousClock.Instant
    ) {
        guard lifecycle == .running else { return }
        if pendingSound != nil { soundPublicationReplacements += 1 }
        let metadata = parent.metadata
        let scopedParent = AgentInput(
            id: parent.id, sessionID: parent.sessionID, payload: parent.payload,
            metadata: InputMetadata(
                payload: parent.payload, source: metadata.source, incarnation: metadata.incarnation,
                origin: metadata.origin,
                capturedAt: metadata.capturedAt, sequence: metadata.sequence, rootID: metadata.rootID,
                parentID: metadata.parentID, hops: metadata.hops,
                deadline: min(metadata.deadline, capturedAt.advanced(by: .milliseconds(500)))),
            turn: parent.turn)
        pendingSound = (value, scopedParent, capturedAt)
        if soundPublisher == nil { soundPublisher = Task { await self.publishSound() } }
    }
    private func publishSound() async {
        defer {
            soundPublisher = nil
            if lifecycle == .running, pendingSound != nil {
                soundPublisher = Task { await self.publishSound() }
            }
        }
        while lifecycle == .running, let publication = pendingSound {
            pendingSound = nil
            guard !publication.parent.metadata.expired,
                publication.capturedAt.duration(to: .now) <= .milliseconds(500)
            else { continue }
            do {
                try Task.checkCancellation()
                guard let port else { return }
                let report = try await port.publishResult(.soundSource(publication.value), parent: publication.parent)
                try Task.checkCancellation()
                // No subscribers and rejected subscribers do not gate either perception branch.
                let failure = report.failure
                let failed = failure != nil && failure != String(describing: CommunicationError.noRecipients)
                soundPublicationRejections += report.rejected.count + (failed ? 1 : 0)
            } catch is CancellationError {
                return
            } catch {
                soundPublicationRejections += 1
            }
        }
    }

}
