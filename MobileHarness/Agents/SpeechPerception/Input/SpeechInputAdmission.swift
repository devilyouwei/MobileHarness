import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import OSLog
import PlatformKit
import StorageCore
import UI

extension SpeechPerceptionAgent {
    func startUIInputs() async throws {
        guard let uiHome, let interactionSessionID else { return }
        let source = await uiHome.listeningRequests
        let task = try await consumeUI(source, sessionID: interactionSessionID) { agent, value, context in
            let enabled: Bool?
            switch value {
            case .setEnabled(let value): enabled = value
            case .toggle: enabled = nil
            case .press(let pressed):
                let call = try InternalTool(path: "Speech.Listening.prepare", required: ["pressed"]).call([
                    "pressed": String(pressed)
                ])
                try await agent.emit(.toolCall(call), input: context.input(.event("listening.press")))
                return
            }
            let intent = ListeningIntent(enabled: enabled)
            let input = try intent.input(sessionID: context.sessionID)
            guard case .observation(let message) = input.payload else { throw CommunicationError.invalidPayload }
            try await agent.receiveListening(context.input(.observation(message)), message: message)
        }
        uiInputs.append(task)
    }
    func stopUIInputs() async { await uiInputs.retire(for: descriptor.id)() }

    private func validateAudio(_ input: AgentInput) throws -> AudioInput {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard input.sessionID == sessionID else { throw CommunicationError.scopeClosed }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        try Task.checkCancellation()
        if let nativeCaptureGeneration, case .audio = input.payload {
            guard input.metadata.generation == nativeCaptureGeneration else { throw CommunicationError.scopeClosed }
        }
        guard case .audio(let audio) = input.payload else { throw HarnessError.unsupportedInput }
        guard
            !residentListening
                || (captureOpen && input.sessionID == sessionID && listeningPolicy.enabled)
        else {
            throw CapabilityError.inputBusy
        }
        // The domain policy gates new capture independently of native playback barriers.
        guard !recognitionSuspended else { throw CapabilityError.inputBusy }
        guard lastSequence.map({ audio.sequence > $0 }) ?? true,
            lastTimestamp.map({ audio.timestamp >= $0 }) ?? true
        else { throw CommunicationError.outOfOrder }
        return audio
    }
    func processMicrophone(_ frame: MicrophoneFrame, sessionID: String, captureGeneration: String) async throws {
        guard !nativeProcessing else { throw CapabilityError.inputBusy }
        let audio = try AudioInput(
            samples: frame.samples, sampleRate: frame.sampleRate,
            sequence: frame.sequence, timestamp: frame.timestamp,
            layout: frame.layout == .mono ? .mono : .firstOrderAmbisonicsACNSN3D, capturedAt: frame.capturedAt)
        let context = ProcessingContext(
            sessionID: sessionID, generation: captureGeneration, source: "phone.microphone", sequence: frame.sequence)
        try context.validate()
        let input = context.input(.audio(audio))
        _ = try validateAudio(input)
        lastSequence = audio.sequence
        lastTimestamp = audio.timestamp
        nativeProcessing = true
        defer {
            nativeProcessing = false
            let pending = nativePacketWaiters.values
            nativePacketWaiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        do { try await processAudio(input) } catch is CancellationError {
            throw CancellationError()
        } catch {
            if mode == .keywordTest { throw error }
            guard lifecycle != .stopped else { throw CancellationError() }
            await recoverRecognition(error)
        }
    }
    func joinNativePacket() async throws {
        guard nativeProcessing else { return }
        guard nativePacketWaiters.count < 32 else { throw CommunicationError.capacityExceeded }
        let id = UUID().uuidString
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    waiter.resume(throwing: CancellationError())
                } else {
                    nativePacketWaiters[id] = waiter
                }
            }
        } onCancel: {
            Task { await self.cancelNativePacketWaiter(id) }
        }
        try Task.checkCancellation()
    }
    private func cancelNativePacketWaiter(_ id: String) {
        nativePacketWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func admitsMicrophone(sessionID: String, capturedAt: ContinuousClock.Instant? = nil) throws -> Bool {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard sessionID == self.sessionID else { throw CommunicationError.scopeClosed }
        if let capturedAt, let microphoneAdmissionOpenedAt, capturedAt < microphoneAdmissionOpenedAt { return false }
        return !recognitionSuspended
            && (!residentListening
                || (captureOpen && listeningPolicy.enabled))
    }

    // MARK: - Context

    func prepareSignal(_ input: AgentInput) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback, retainingLast: SpeechPerceptionSignalPreprocessor.evidenceCapacity)
    }
}
