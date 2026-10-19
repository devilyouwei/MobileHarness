import AgentCore
import Foundation
import ModelKit
import PlatformKit
import StorageCore

/// Streaming perception only. Device capture and playback remain composition-owned.
public actor SpeechPerceptionAgent: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    private let contextRepository: AgentContextRepository<SpeechPerceptionContextState>
    private let preprocessor = SpeechPerceptionSignalPreprocessor()
    private let contextBuilder = SpeechPerceptionContextBuilder()

    /// Host-selected diagnostic scope; model capabilities/permissions remain in the versioned configuration.
    public enum Mode: Sendable { case speechAndSoundSource, soundSourceOnly }
    private let mode: Mode
    private static let transcript = InternalTool(path: "UI.Caption.setTranscript", required: ["text"])
    private static let voiceState = InternalTool(path: "UI.VoiceState.setVoiceState", required: ["state"])
    private static let finishTranscript = InternalTool(path: "UI.Caption.finishTranscript")
    private var resultInbox = ActionResultInbox()
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let recognition: any SpeechRecognitionCapability
    private let vad: any VoiceActivityCapability
    private let resampler: StreamingMonoPCMResampler
    private var sessionID: String
    private let interactionSessionID: String?
    private let residentListening: Bool
    private var captureOpen: Bool
    private var listeningPolicy = SpeechListeningPolicy()
    private static let listeningAction = InternalAction(
        domain: "Speech", module: "Listening", function: "update", channel: "Listening",
        required: ["enabled", "paused", "revision"])
    private var segmenter: VoiceActivitySegmenter?
    private var recognitionTurn: SpeechRecognitionTurn?
    private var lifecycle: AgentLifecycle = .registered
    private var queue: [AgentInput] = []
    private var queuedSamples = 0
    private var queuedDuration: TimeInterval = 0
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

    // MARK: - Registration

    public init(
        recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
        sessionID: String, interactionSessionID: String? = nil, configuration: AgentConfiguration? = nil,
        mode: Mode = .speechAndSoundSource, residentListening: Bool = false,
        context: AgentContextRepository<SpeechPerceptionContextState>
    ) throws {
        if residentListening {
            guard interactionSessionID != nil else { throw CommunicationError.scopeClosed }
            if case .soundSourceOnly = mode { throw CommunicationError.invalidPayload }
        }
        self.contextRepository = context
        guard contextRepository.agentID == .speechPerception else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: "SpeechPerception")
        guard configuration.agentID == .speechPerception else { throw AgentConfigurationError.identityMismatch }
        self.resampler = try StreamingMonoPCMResampler(outputSampleRate: 16000)
        self.recognition = recognition
        self.vad = vad
        self.sessionID = sessionID
        self.interactionSessionID = interactionSessionID
        self.mode = mode
        self.residentListening = residentListening
        self.captureOpen = !residentListening
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: "Speech Perception",
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: mode == .speechAndSoundSource
                ? [.communication, .actionCall, .toolCall, .control] : [.communication, .control],
            capabilities: try mode == .speechAndSoundSource
                ? Self.runtimeCapabilities(configuration.capabilities) : configuration.capabilities)
        let stream = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(SpeechPerceptionSignalPreprocessor.outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public nonisolated static func runtimeCapabilities(_ model: CapabilityRegistry) throws -> CapabilityRegistry {
        try model.adding(internalActions: [listeningAction], internalTools: [transcript, voiceState, finishTranscript])
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        if mode == .soundSourceOnly || residentListening {
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
    public func isUtteranceActive() -> Bool { phase == .speaking || phase == .processing }
    public func acquirePlaybackAdmission() -> Bool {
        guard lifecycle == .running, !isUtteranceActive() else { return false }
        awaitingReply = true
        clearPendingAudio()
        return true
    }
    public func pauseAudioAdmission() throws {
        guard acquirePlaybackAdmission() else { throw CapabilityError.inputBusy }
    }
    public func resumeListening() async throws {
        guard lifecycle == .running, awaitingReply else { return }
        guard !residentListening || (captureOpen && listeningPolicy.enabled && !listeningPolicy.paused) else { return }
        // Wait for final publication to finish before resetting its ASR/VAD state.
        await worker?.value
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard !residentListening || (captureOpen && listeningPolicy.enabled && !listeningPolicy.paused) else { return }
        guard let activeInput else {
            awaitingReply = false
            phase = .listening
            return
        }
        try await resetListening(after: activeInput)
        guard !awaitingReply else { return }
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

    /// A microphone epoch is independent of the resident policy Agent's lifetime.
    public func openCapture(sessionID: String) async throws {
        guard residentListening, lifecycle == .running, listeningPolicy.enabled else {
            throw HarnessError.notRunning
        }
        await closeCapture()
        guard lifecycle == .running, listeningPolicy.enabled else { throw HarnessError.notRunning }
        self.sessionID = sessionID
        captureOpen = true
        awaitingReply = listeningPolicy.paused
        phase = .listening
        prepareRecognitionTurn()
    }
    public func closeCapture() async {
        captureOpen = false
        clearPendingAudio()
        worker?.cancel()
        await recognitionTurn?.cancel()
        await segmenter?.cancel()
        await worker?.value
        worker = nil
        soundPublisher?.cancel()
        await soundPublisher?.value
        soundPublisher = nil
        pendingSound = nil
        recognitionTurn = nil
        segmenter = nil
        activeInput = nil
        currentTurn = nil
        lastSequence = nil
        lastTimestamp = nil
        soundEstimator.reset()
        await resampler.reset()
    }

    private func receiveListening(_ input: AgentInput, message: AgentMessage) async throws {
        guard residentListening, input.sessionID == interactionSessionID else { throw CommunicationError.scopeClosed }
        if message.contract == ListeningIntent.contract {
            guard input.metadata.origin == .external, input.metadata.source == "user",
                let intent = message.content(as: ListeningIntent.self)
            else { throw CommunicationError.unauthorized }
            try await prepareSignal(input)
            listeningPolicy.enabled = intent.enabled ?? !listeningPolicy.enabled
            if !listeningPolicy.enabled { listeningPolicy.pendingFinal = nil }
        } else if message.contract == SpeechCaptureEnded.contract {
            guard input.metadata.origin == .external, input.metadata.source == "phone.microphone",
                let ended = message.content(as: SpeechCaptureEnded.self)
            else { throw CommunicationError.unauthorized }
            try await prepareSignal(input)
            guard ended.revision == listeningPolicy.revision, listeningPolicy.enabled else { return }
            listeningPolicy.enabled = false
            listeningPolicy.pendingFinal = nil
        } else {
            guard input.metadata.origin == .agent, let incarnation = input.metadata.incarnation,
                let activity = message.content(as: ReplyActivity.self),
                ["assistant", "photographer", "memory", "applicationControl"].contains(input.metadata.source)
            else { throw CommunicationError.unauthorized }
            try activity.validate()
            try await prepareSignal(input)
            guard try listeningPolicy.accept(activity, source: input.metadata.source, incarnation: incarnation) else {
                return
            }
        }
        try applyListeningPolicy(parent: input)
    }
    private func applyListeningPolicy(parent: AgentInput) throws {
        guard let interactionSessionID else { throw CommunicationError.scopeClosed }
        listeningPolicy.revision += 1
        let payload = InputPayload.text("Listening policy")
        let command = AgentInput(
            id: UUID().uuidString,
            sessionID: interactionSessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "speechPerception", origin: .agent,
                rootID: parent.metadata.rootID, parentID: parent.id))
        // Close the Agent gate synchronously when no confirmed utterance must finish first.
        if !listeningPolicy.enabled || listeningPolicy.paused, !isUtteranceActive() {
            awaitingReply = true
            clearPendingAudio()
        }
        try emit(
            .actionCall(
                Self.listeningAction.call([
                    "enabled": String(listeningPolicy.enabled), "paused": String(listeningPolicy.paused),
                    "revision": String(listeningPolicy.revision),
                ])), input: command)
        try emit(.control("agent.finished"), input: command)
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {

        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        if case .observation(let message) = input.payload,
            [ListeningIntent.contract, ReplyActivity.contract, SpeechCaptureEnded.contract].contains(message.contract)
        {
            guard !input.metadata.expired else { throw CommunicationError.expired }
            try await receiveListening(input, message: message)
            return
        }
        guard input.sessionID == sessionID || (residentListening && input.sessionID == interactionSessionID) else {
            throw CommunicationError.scopeClosed
        }
        guard !input.metadata.expired else { throw CommunicationError.expired }
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
        guard case .audio(let audio) = input.payload else { throw HarnessError.unsupportedInput }
        guard
            !residentListening
                || (captureOpen && input.sessionID == sessionID && listeningPolicy.enabled
                    && (!listeningPolicy.paused || isUtteranceActive()))
        else {
            throw CapabilityError.inputBusy
        }
        // The domain policy gates new capture independently of native playback barriers.
        guard !awaitingReply else { throw CapabilityError.inputBusy }
        guard lastSequence.map({ audio.sequence > $0 }) ?? true,
            lastTimestamp.map({ audio.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        guard queue.count < SpeechPerceptionSignalPreprocessor.inputCapacity,
            queuedSamples + audio.sampleCount <= SpeechPerceptionSignalPreprocessor.maximumQueuedSamples,
            queuedDuration + Double(audio.frameCount) / Double(audio.sampleRate)
                <= SpeechPerceptionSignalPreprocessor.maximumQueuedDuration + 1e-9
        else {
            reportError(HarnessError.queueFull, input: input)
            throw HarnessError.queueFull
        }
        lastSequence = audio.sequence
        lastTimestamp = audio.timestamp
        queue.append(input)
        queuedSamples += audio.sampleCount
        queuedDuration += Double(audio.frameCount) / Double(audio.sampleRate)
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
        guard lifecycle == .running || lifecycle == .paused, let parent = activeInput else {
            throw CancellationError()
        }
        try await communicate(.transcript(text, final: false), parent: parent)
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
        let storedPhase = next == .empty ? SpeechPhase.listening : next
        try await contextRepository.update {
            $0.state.phase = storedPhase.rawValue
            if next == .speaking { $0.state.utteranceCount += 1 }
            try $0.append(
                .init(taskID: input.turn?.id, kind: "speech.phase", data: Data(next.rawValue.utf8)),
                retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
        }
        phase = storedPhase
        try presentPhase(next, input: input)
        if publish { try await communicate(.speechPhase(next), parent: input) }
    }
    private func resetListening(after input: AgentInput) async throws {
        soundEstimator.reset()
        soundLayout = nil
        soundRate = nil
        await resampler.reset()
        try await segmenter?.reset()
        prepareRecognitionTurn()
        awaitingReply = residentListening && (!captureOpen || !listeningPolicy.enabled || listeningPolicy.paused)
        activeInput = input
    }
    private func clearPendingAudio() {
        queue.removeAll()
        queuedSamples = 0
        queuedDuration = 0
    }

    // MARK: - Decision workers

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
            await recoverRecognition(error)
        }
    }
    private func processAudio(_ acceptedInput: AgentInput) async throws {
        let input = acceptedInput
        let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
        let decision = try contextBuilder.build(state: selection, batch: selection.batch())
        guard case .audio(let audio) = decision.input.payload else { throw HarnessError.unsupportedInput }
        queuedSamples -= audio.sampleCount
        queuedDuration = max(0, queuedDuration - Double(audio.frameCount) / Double(audio.sampleRate))
        guard !input.metadata.expired else { throw CommunicationError.expired }
        if mode == .speechAndSoundSource, segmenter == nil {
            let session = try await vad.detectVoiceActivity(
                format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32))
            guard lifecycle == .running, !Task.isCancelled else {
                await session.cancel()
                throw CancellationError()
            }
            segmenter = VoiceActivitySegmenter(session: session)
        }
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
                    frame, input: input, segmenter: segmenter, recognitionTurn: recognitionTurn)
                timestamp += packet.duration
            }
        }
    }
    private func processFrame(
        _ frame: AudioFrame, input acceptedInput: AgentInput, segmenter: VoiceActivitySegmenter,
        recognitionTurn: SpeechRecognitionTurn
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
            currentTurn = AgentTurn(id: UUID().uuidString, ordinal: turnOrdinal)
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
            try await finishUtterance(input: input, recognitionTurn: recognitionTurn)
        }
    }
    private func finishUtterance(
        input: AgentInput, recognitionTurn: SpeechRecognitionTurn
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
        try emit(.toolCall(Self.transcript.call(["text": String(text.suffix(320))])), input: input)
        try emit(.toolCall(Self.finishTranscript.call([:])), input: input)
        try emit(.control("agent.finished"), input: input)
        if text.isEmpty {
            try await resetListening(after: input)
            try await transition(to: .empty, input: input)
            return
        }
        phase = .listening
        if residentListening {
            listeningPolicy.pendingFinal = input.metadata.rootID
            try applyListeningPolicy(parent: input)
        }
        try await communicate(.transcript(text, final: true), parent: input)
        // The reply producer reports occupancy; no subscriber receipt is expected.
    }
    private func reportError(_ error: any Error, input: AgentInput) {
        outputSequence += 1
        continuation.yield(
            OutputEnvelope(
                source: descriptor.id, input: input,
                output: .control("agent.error: speech perception: \(error)"), sequence: outputSequence))
    }

    /// A failed utterance does not close the resident Agent, microphone or output stream.
    private func recoverRecognition(_ error: any Error) async {
        if let activeInput {
            reportError(error, input: activeInput)
            if listeningPolicy.pendingFinal == activeInput.metadata.rootID {
                listeningPolicy.pendingFinal = nil
                do { try applyListeningPolicy(parent: activeInput) } catch { reportError(error, input: activeInput) }
            }
        }
        clearPendingAudio()
        await recognitionTurn?.cancel()
        await segmenter?.cancel()
        segmenter = nil
        await resampler.reset()
        soundEstimator.reset()
        awaitingReply = residentListening && (!listeningPolicy.enabled || listeningPolicy.paused)
        phase = .listening
        prepareRecognitionTurn()
        // VAD is rebuilt lazily on the next frame, keeping repeated provider failures recoverable.
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
                deadline: min(
                    metadata.deadline ?? capturedAt.advanced(by: .milliseconds(500)),
                    capturedAt.advanced(by: .milliseconds(500)))),
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
                try await communicate(.soundSource(publication.value), parent: publication.parent)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                soundPublicationRejections += 1
                reportError(error, input: publication.parent)
            }
        }
    }

    // MARK: - Output

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

    // MARK: - Communication output

    private func communicate(_ message: AgentMessage, parent: AgentInput) async throws {
        var parent = parent
        if let interactionSessionID, ["speech.final", "speech.phase"].contains(message.contract) {
            parent = AgentInput(
                id: parent.id, sessionID: interactionSessionID, payload: parent.payload,
                metadata: parent.metadata, turn: parent.turn, taskScope: parent.taskScope)
        }
        let causalParent = parent
        let action = try CommunicationAction(message: message)
        let evidence = try JSONEncoder().encode(
            SignalEvidence(
                AgentInput(
                    id: action.id, sessionID: causalParent.sessionID, payload: .observation(message),
                    metadata: causalParent.metadata, turn: causalParent.turn, taskScope: causalParent.taskScope)))
        try await contextRepository.update {
            try $0.append(
                .init(
                    id: action.id, taskID: causalParent.taskScope?.id ?? causalParent.id,
                    kind: "communication.output", data: evidence),
                retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
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
            consumed: disposition != .feedback, retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
    }

    // MARK: - Observability

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: queue.count, processedInputs: processed)
    }

    public func contextSnapshot() async throws -> AgentContext<SpeechPerceptionContextState> {
        try await contextRepository.snapshot()
    }
    public func actionResults() -> [ActionResult] { resultInbox.results }
}
