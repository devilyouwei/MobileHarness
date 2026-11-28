import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import OSLog
import PlatformKit
import StorageCore
import UI

extension SpeechPerceptionAgent {
    func preview(_ text: String) async throws {
        guard lifecycle == .running || lifecycle == .paused, let parent = activeInput else {
            throw CancellationError()
        }
        try presentTranscript(text, input: parent)
        if parent.turn != nil, let vadGeneration {
            do {
                try await communicate(
                    SpeechRecognition(.partial, text: text, generation: vadGeneration).message(),
                    parent: parent, evidence: .none)
            } catch {
                Logger(subsystem: "dev.mobileharness", category: "SpeechRecognition").error(
                    "Partial transcript not published: \(String(describing: error), privacy: .public)")
            }
        }
    }
    func presentTranscript(_ text: String, input: AgentInput) throws {
        try Task.checkCancellation()
        guard lifecycle == .running || lifecycle == .paused else { throw CancellationError() }
        // Presentation is bounded separately from the complete shared transcription.
        let call = try Self.transcript.call(["text": String(text.suffix(320))])
        try emit(.toolCall(call), input: input)
        // Close output bookkeeping after this immediate display update completes.
        try emit(.control("agent.finished"), input: input)
    }
    func presentPhase(_ phase: SpeechPhase, input: AgentInput) throws {
        let state = phase == .processing ? "processing" : phase == .speaking ? "hearing" : "listening"
        let call = try Self.voiceState.call(["state": state])
        try emit(.toolCall(call), input: input)
        try emit(.control("agent.finished"), input: input)
    }
    /// Owns recognition phase and its local presentation.

    // MARK: - Output

    func emit(_ output: AgentOutput, input: AgentInput) throws {
        outputSequence += 1
        switch continuation.yield(
            OutputEnvelope(
                source: descriptor.id, context: input.context, output: output, sequence: outputSequence,
                taskScope: input.taskScope))
        {
        case .enqueued: return
        case .dropped, .terminated: throw HarnessError.queueFull
        @unknown default: throw HarnessError.queueFull
        }
    }

    // MARK: - Voice activity

    func beginVADCapture() async {
        guard mode == .speechAndSoundSource, vadGeneration == nil else { return }
        let generation = UUID().uuidString
        vadGeneration = generation
        vadWindowSequence = 0
        publishedVADWindowSequence = 0
        recentVADWindows.removeAll(keepingCapacity: true)
        await publishSpeech(SpeechActivity(.captureStarted, generation: generation))
    }

    func endVADCapture() async {
        guard let generation = vadGeneration else { return }
        vadGeneration = nil
        utteranceEnergy = nil
        onsetCandidatePublished = false
        resetKeywordProbe()
        await publishSpeech(SpeechActivity(.captureStopped, generation: generation))
        await keywordRetirement?.value
    }

    private func publishSpeech(_ activity: SpeechActivity) async {
        guard let interactionSessionID else { return }
        let parent = AgentInput(
            id: UUID().uuidString, sessionID: interactionSessionID, payload: .event("speech.activity"))
        do {
            try await communicate(
                activity.message(), parent: parent,
                evidence: activity.kind == .vadProgress || activity.kind == .energyChanged ? .none : .afterPublication)
        } catch {
            Logger(subsystem: "dev.mobileharness", category: "SpeechActivity").error(
                "\(activity.kind.rawValue, privacy: .public) not published: \(String(describing: error), privacy: .public)"
            )
        }
    }

    func reportVAD(
        _ windows: [VoiceSegmentation.Window], capturedAt: ContinuousClock.Instant, confirmed utterance: String?
    ) async {
        guard let generation = vadGeneration else { return }
        let confirmation = utterance == nil ? nil : windows.firstIndex(where: \.speaking) ?? windows.indices.last
        for (index, window) in windows.enumerated() {
            guard vadGeneration == generation else { return }
            await publishOnset(candidate: window.onsetCandidate, confirmed: index == confirmation ? utterance : nil)
            guard vadGeneration == generation else { return }
            if index == confirmation, let utterance, utteranceEnergy == nil {
                utteranceEnergy = (utterance, SpeechEnergyBands())
            }
            if let utterance = utteranceEnergy?.utterance {
                let energy = utteranceEnergy?.policy.observe(window.pcm)
                if !window.speaking, utteranceEnergy?.policy.isQuiet == true { utteranceEnergy = nil }
                if let energy {
                    await publishSpeech(
                        SpeechActivity(.energyChanged, generation: generation, utterance: utterance, energy: energy))
                    guard vadGeneration == generation else { return }
                }
            }
            guard window.sampleCount == 512 else { continue }
            let start = capturedAt + .nanoseconds(window.offset * 62_500)
            recentVADWindows.append(SpeechSignalClock.offset(at: start))
            if recentVADWindows.count > SpeechActivity.progressWindowCount { recentVADWindows.removeFirst() }
            vadWindowSequence += 1
            if vadWindowSequence - publishedVADWindowSequence >= 4 { await publishVADProgress() }
        }
    }

    private func publishVADProgress() async {
        guard let generation = vadGeneration, vadWindowSequence > publishedVADWindowSequence else { return }
        publishedVADWindowSequence = vadWindowSequence
        let oldest = recentVADWindows.count == SpeechActivity.progressWindowCount ? recentVADWindows.first : nil
        await publishSpeech(
            SpeechActivity(
                .vadProgress, generation: generation, sequence: vadWindowSequence, oldestWindow: oldest))
    }

    private func publishOnset(candidate: Bool, confirmed utterance: String?) async {
        guard let generation = vadGeneration else { return }
        if !onsetCandidatePublished, utterance != nil || candidate {
            let preceding = recentVADWindows.count == SpeechActivity.progressWindowCount ? recentVADWindows.first : nil
            oldestWindowBeforeOnset = preceding
            await publishVADProgress()
            guard vadGeneration == generation else { return }
            onsetCandidatePublished = true
            await publishSpeech(
                SpeechActivity(
                    .onsetStarted, generation: generation,
                    oldestWindowBeforeOnset: preceding))
            guard vadGeneration == generation else { return }
        }
        if let utterance {
            onsetCandidatePublished = false
            await publishSpeech(
                SpeechActivity(
                    .onsetConfirmed, generation: generation, utterance: utterance,
                    oldestWindowBeforeOnset: oldestWindowBeforeOnset))
        } else if onsetCandidatePublished, !candidate {
            onsetCandidatePublished = false
            await publishSpeech(SpeechActivity(.onsetCleared, generation: generation))
        }
    }

    // MARK: - Communication output

    enum PublicationEvidence: Equatable {
        case beforePublication, afterPublication, none
    }

    func communicate(
        _ message: AgentMessage, parent: AgentInput, evidence: PublicationEvidence = .afterPublication
    ) async throws {
        var parent = parent
        if let interactionSessionID, message.contract == SpeechRecognition.contract {
            parent = AgentInput(
                id: parent.id, sessionID: interactionSessionID, payload: parent.payload,
                metadata: parent.metadata, turn: parent.turn, taskScope: parent.taskScope)
        }
        let action = try CommunicationAction(message: message)
        if evidence == .beforePublication {
            try await recordCommunication(action, parent: parent)
            try Task.checkCancellation()
            guard !parent.metadata.expired else { throw CommunicationError.expired }
        }
        try emit(.communication(action), input: parent)
        if evidence == .afterPublication {
            do {
                try await recordCommunication(action, parent: parent)
            } catch {
                Logger(subsystem: "dev.mobileharness", category: "SpeechActivity").error(
                    "Could not record \(message.contract, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func recordCommunication(_ action: CommunicationAction, parent: AgentInput) async throws {
        let input = AgentInput(
            id: action.id, sessionID: parent.sessionID, payload: .observation(action.message),
            metadata: parent.metadata, turn: parent.turn, taskScope: parent.taskScope)
        let evidence = try JSONEncoder().encode(SignalEvidence(input))
        try await contextRepository.update {
            try $0.append(
                .init(
                    id: action.id, taskID: parent.taskScope?.id ?? parent.id,
                    kind: "communication.output", data: evidence),
                retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
        }
    }
}
