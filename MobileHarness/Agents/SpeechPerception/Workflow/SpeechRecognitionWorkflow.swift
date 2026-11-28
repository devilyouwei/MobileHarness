import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import OSLog
import PlatformKit
import StorageCore
import UI

extension SpeechPerceptionAgent {
    func prepareRecognitionTurn() {
        currentTurn = nil
        publishedRecognitionFinal = false
        recognitionTurn = SpeechRecognitionTurn(recognition: recognition, sessionID: sessionID) { [weak self] text in
            guard let self else { throw CancellationError() }
            try await self.preview(text)
        }
    }

    func transition(
        to next: SpeechPhase, input: AgentInput, present: Bool = true
    ) async throws {
        // Empty ends the current turn and returns capture to listening.
        let storedPhase = next == .empty ? SpeechPhase.listening : next
        try await contextRepository.update {
            $0.state.phase = storedPhase.rawValue
            if next == .speaking { $0.state.utteranceCount += 1 }
            try $0.append(
                .init(taskID: input.turn?.id, kind: "recognition.phase", data: Data(next.rawValue.utf8)),
                retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
        }
        phase = storedPhase
        await refreshIsland()
        if present { try presentPhase(next, input: input) }
    }
    func resetListening(
        after input: AgentInput, discardEarlierPCM: Bool = false, requireFreshOnset: Bool = false,
        acceptedTranscript: Bool = false
    ) async throws {
        resetKeywordProbe()
        let captureSession = sessionID
        let captureGeneration = nativeCaptureGeneration
        let admission = playbackAdmission
        if discardEarlierPCM {
            soundEstimator.reset()
            soundLayout = nil
            soundRate = nil
            await pcmPreparation.reset()
        }
        try await segmenter?.reset(requireFreshOnset: requireFreshOnset, acceptedTranscript: acceptedTranscript)
        try Task.checkCancellation()
        guard lifecycle == .running, sessionID == captureSession, nativeCaptureGeneration == captureGeneration else {
            throw CancellationError()
        }
        prepareRecognitionTurn()
        if discardEarlierPCM { microphoneAdmissionOpenedAt = .now }
        recognitionSuspended =
            admission != playbackAdmission || (residentListening && (!captureOpen || !listeningPolicy.enabled))
        activeInput = input
    }
    // MARK: - Inline native packet processing

    func processAudio(_ acceptedInput: AgentInput) async throws {
        let input = acceptedInput
        let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
        let decision = try contextBuilder.build(state: selection, batch: selection.batch())
        guard case .audio(let audio) = decision.input.payload else { throw HarnessError.unsupportedInput }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        if mode == .speechAndSoundSource, segmenter == nil {
            detectionSettings = try await speechDetection()
            let session = try await vad.detectVoiceActivity(
                format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32))
            guard lifecycle == .running, !Task.isCancelled else {
                await session.cancel()
                throw CancellationError()
            }
            segmenter = VoiceActivitySegmenter(session: session, endpointConfirmation: endpointConfirmation)
        }
        if mode == .speechAndSoundSource, !recognitionSuspended, vadGeneration == nil { await beginVADCapture() }
        let playback = await microphoneInput?.playbackSnapshot() ?? .init()
        let samples = audio.samples
        try Task.checkCancellation()
        if mode == .soundSourceOnly { activeInput = input }
        if let segmenter, calibrationFormat?.layout != audio.layout || calibrationFormat?.rate != audio.sampleRate {
            let captureGeneration = nativeCaptureGeneration
            await segmenter.resetLevelCalibration()
            guard nativeCaptureGeneration == captureGeneration else { return }
            calibrationFormat = (audio.layout, audio.sampleRate)
        }
        if soundLayout != audio.layout || soundRate != audio.sampleRate {
            soundEstimator.reset()
            await pcmPreparation.reset()
            soundLayout = audio.layout
            soundRate = audio.sampleRate
            if audio.layout == .mono {
                enqueueSound(
                    .init(state: .unavailable, timestamp: audio.timestamp, duration: 0), parent: input,
                    capturedAt: audio.capturedAt)
            }
        }
        // Spatial DSP is independent of the speech detector and uses native-rate channels.
        if mode != .keywordTest, audio.layout == .firstOrderAmbisonicsACNSN3D {
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
        let mono = audio.layout == .mono ? samples : stride(from: 0, to: samples.count, by: 4).map { samples[$0] }
        let step = max(1, min(8192, audio.sampleRate * 32 / 1000))
        for offset in stride(from: 0, to: mono.count, by: step) {
            let end = min(offset + step, mono.count)
            let packets = try await pcmPreparation.process(
                MicrophoneFrame(
                    samples: Array(mono[offset..<end]),
                    sampleRate: audio.sampleRate, sequence: audio.sequence),
                timestamp: audio.timestamp + Double(offset) / Double(audio.sampleRate))
            for packet in packets {
                // Preserve bounded slices and capture-time playback facts for onset thresholds.
                for sample in stride(from: 0, to: packet.sampleCount, by: 512) {
                    guard !recognitionSuspended else { break }
                    let count = min(512, packet.sampleCount - sample)
                    let frame = try AudioFrame(
                        data: packet.data.subdata(in: sample * 4..<(sample + count) * 4), format: packet.format,
                        sequence: speechFrameSequence, timestamp: packet.timestamp + Double(sample) / 16000)
                    speechFrameSequence += 1
                    if mode == .keywordTest {
                        guard let keywordTestAudio else { throw HarnessError.invalidTransition }
                        try await keywordTestAudio(frame.floatSamples)
                        continue
                    }
                    guard let segmenter, let recognitionTurn else { throw HarnessError.invalidTransition }
                    let start = audio.capturedAt.advanced(by: .seconds(frame.timestamp - audio.timestamp))
                    try await processFrame(
                        frame, input: input, segmenter: segmenter, recognitionTurn: recognitionTurn,
                        playing: playback.isPlaying(at: start, tail: .milliseconds(200)),
                        useShortEndpoint: playback.isPlaying(at: start), capturedAt: start)
                }
            }
        }
    }

    private func processFrame(
        _ frame: AudioFrame, input acceptedInput: AgentInput, segmenter: VoiceActivitySegmenter,
        recognitionTurn: SpeechRecognitionTurn, playing: Bool, useShortEndpoint: Bool,
        capturedAt: ContinuousClock.Instant
    ) async throws {
        let captureGeneration = vadGeneration
        activeInput = acceptedInput.assigning(turn: currentTurn)
        try Task.checkCancellation()
        let onset = SpeechOnsetPolicy(
            windows: detectionSettings.windows, threshold: detectionSettings.threshold, playing: playing)
        let result = try await segmenter.process(
            frame, threshold: onset.threshold, onsetWindows: onset.onsetWindows,
            useShortEndpoint: useShortEndpoint,
            onsetThreshold: onset.onsetThreshold, playing: playing)
        try Task.checkCancellation()
        guard vadGeneration == captureGeneration else { return }
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
            traceOnset(
                onset, playing: playing, probability: result.probability, level: frame.rmsDecibels,
                gates: result.levelGates)
        }
        await reportVAD(
            result.windows, capturedAt: capturedAt, confirmed: beganTurn ? currentTurn?.id : nil)
        guard vadGeneration == captureGeneration else { return }
        await updateKeywordProbe(result.windows, capturedAt: capturedAt)
        guard vadGeneration == captureGeneration else { return }
        let input = acceptedInput.assigning(turn: currentTurn)
        activeInput = input
        if beganTurn { try presentTranscript("", input: input) }
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
        } else if await recognitionTurn.reachedNoTextEndpoint {
            try await finishUtterance(input: input, recognitionTurn: recognitionTurn, noTextEndpoint: true)
        }
    }
    private func finishUtterance(
        input: AgentInput, recognitionTurn: SpeechRecognitionTurn, noTextEndpoint: Bool = false
    ) async throws {
        let captureGeneration = vadGeneration
        resetKeywordProbe()
        recognitionSuspended = true
        phase = .processing
        soundEstimator.reset()
        if soundLayout == .firstOrderAmbisonicsACNSN3D, case .audio(let audio) = input.payload {
            enqueueSound(
                .init(state: .inactive, timestamp: audio.timestamp, duration: 0), parent: input,
                capturedAt: audio.capturedAt)
        }
        // Keep the current turn closed while the recognizer seals its final text.
        try await transition(to: .processing, input: input)
        let text = try await recognitionTurn.finish(noTextGrace: noTextEndpoint ? .milliseconds(500) : nil)
        try Task.checkCancellation()
        // A completed utterance resets preprocessing history without a timed admission delay.
        if input.turn != nil {
            await pcmPreparation.reset()
        }
        guard vadGeneration == captureGeneration else { return }
        try emit(.toolCall(Self.transcript.call(["text": String(text.suffix(320))])), input: input)
        try emit(.toolCall(Self.finishTranscript.call([:])), input: input)
        try emit(.control("agent.finished"), input: input)
        if input.turn != nil {
            try await communicate(
                SpeechRecognition(
                    .final, text: text, generation: captureGeneration, oldestWindowBeforeOnset: oldestWindowBeforeOnset
                ).message(), parent: input)
            guard vadGeneration == captureGeneration else { return }
            publishedRecognitionFinal = true
        }
        try await resetListening(
            after: input, requireFreshOnset: noTextEndpoint,
            acceptedTranscript: !noTextEndpoint && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try await transition(to: text.isEmpty ? .empty : .listening, input: input, present: !recognitionSuspended)
    }
    func reportError(_ error: any Error, input: AgentInput) {
        outputSequence += 1
        continuation.yield(
            OutputEnvelope(
                source: descriptor.id, context: input.context,
                output: .control("agent.error: speech perception: \(error)"), sequence: outputSequence,
                taskScope: input.taskScope))
    }

    /// A failed utterance does not close the resident Agent, microphone or output stream.
    func recoverRecognition(_ error: any Error) async {
        let captureGeneration = vadGeneration
        resetKeywordProbe()
        let failedInput = activeInput?.assigning(turn: currentTurn)
        if let failedInput, failedInput.turn != nil, !publishedRecognitionFinal {
            let detail = String(decoding: String(describing: error).utf8.prefix(496), as: UTF8.self)
            do {
                try await communicate(
                    SpeechRecognition(
                        .final, text: "", generation: captureGeneration, failure: detail,
                        oldestWindowBeforeOnset: oldestWindowBeforeOnset
                    ).message(),
                    parent: failedInput)
            } catch { reportError(error, input: failedInput) }
        }
        guard vadGeneration == captureGeneration else { return }
        let failedSession = sessionID
        let failedGeneration = nativeCaptureGeneration
        let failedRecognition = recognitionTurn
        let failedSegmenter = segmenter
        await endVADCapture()
        guard vadGeneration == nil, sessionID == failedSession, nativeCaptureGeneration == failedGeneration else {
            return
        }
        if let failedInput { reportError(error, input: failedInput) }
        await failedRecognition?.cancel()
        await failedSegmenter?.cancel()
        guard lifecycle == .running, sessionID == failedSession, nativeCaptureGeneration == failedGeneration else {
            return
        }
        segmenter = nil
        await pcmPreparation.reset()
        guard lifecycle == .running, sessionID == failedSession, nativeCaptureGeneration == failedGeneration else {
            return
        }
        soundEstimator.reset()
        recognitionSuspended = residentListening && (!captureOpen || !listeningPolicy.enabled)
        phase = .listening
        await refreshIsland()
        prepareRecognitionTurn()
        // VAD is rebuilt lazily on the next frame, keeping repeated provider failures recoverable.
        guard let failedInput else { return }
        do {
            try emit(.toolCall(Self.finishTranscript.call([:])), input: failedInput)
            try emit(.control("agent.finished"), input: failedInput)
        } catch { reportError(error, input: failedInput) }
        do {
            // Close the failed recognition and publish its local presentation state.
            try await transition(to: .empty, input: failedInput, present: !recognitionSuspended)
        } catch { reportError(error, input: failedInput) }
    }
}

extension AgentInput {
    /// Same signal identity bound to the current recognition turn.
    func assigning(turn: AgentTurn?) -> AgentInput {
        AgentInput(id: id, sessionID: sessionID, payload: payload, metadata: metadata, turn: turn)
    }
}
