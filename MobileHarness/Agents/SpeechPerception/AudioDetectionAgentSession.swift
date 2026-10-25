import FunctionContracts
import PlatformKit
import UI

public typealias AudioDetectionObservation = DetectionObservation<
    MicrophoneChannelLayout, AudioDetectionSnapshot.Direction
>
public typealias AudioDetectionConnections = DetectionConnections<any AudioCaptureObserving, AudioDetectionObservation>

#if os(iOS)
    import AgentCore
    import Foundation
    import Gateway
    import ModelKit

    /// Owns the isolated diagnostic role and its bound result pump; never opens native hardware.
    @MainActor final class AudioDetectionAgentSession {
        private let id: String
        private let gateway: AgentObservationAccess
        private var session: AgentObservationSession?
        private let policy: CommunicationPolicy
        private let speech: SpeechPerceptionAgent
        private let observe: @MainActor (AudioDetectionObservation) -> Void
        private var outputTask: Task<Void, Never>?
        private var closing = false
        init(
            gateway: AgentObservationAccess, id: String, recognition: any SpeechRecognitionCapability,
            vad: any VoiceActivityCapability,
            input nativeInput: any AudioCaptureObserving,
            observe: @escaping @MainActor (AudioDetectionObservation) -> Void
        ) throws {
            self.gateway = gateway
            self.id = id
            self.observe = observe
            let configuration = try AgentConfigurations.load(named: "SpeechPerception").restrictingCommunication(
                to: ["sound.source"], contracts: AgentContracts.communication)
            policy = try CommunicationPolicy(contracts: AgentContracts.communication, configurations: [configuration])
            speech = try SpeechPerceptionAgent(
                recognition: recognition, vad: vad, sessionID: id, configuration: configuration, mode: .soundSourceOnly,
                microphoneInput: nativeInput,
                microphoneObservation: { observe(.microphone($0.layout, $0.sampleRate, $0.rms, $0.capturedAt)) },
                context: AgentContextRepository(
                    agent: .speechPerception, scope: "00000000-0000-0000-0000-000000000002",
                    state: SpeechPerceptionContextState()))
        }
        static func connections(
            recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
            gateway: AgentObservationAccess
        ) -> AudioDetectionConnections {
            AudioDetectionConnections { id, input, observe, fail in
                let owner = try AudioDetectionAgentSession(
                    gateway: gateway, id: id, recognition: recognition, vad: vad, input: input, observe: observe)
                do {
                    try await owner.start(fail: fail)
                    return AudioDetectionPerception(
                        perception: owner.speech,
                        stop: {
                            do { try await owner.stop() } catch { await fail(error) }
                        })
                } catch {
                    let primary = error
                    do { try await owner.stop() } catch {
                        throw AgentFailure(
                            component: "detection", operation: "start", underlying: primary, cleanupErrors: [error])
                    }
                    throw primary
                }
            }
        }
        private func start(fail: @escaping @MainActor (any Error) async -> Void) async throws {
            let session = try gateway.open(
                policy: policy, observedContracts: ["sound.source"],
                observeEvent: { [weak self] in await self?.observe($0) })
            self.session = session
            let manager = session.capabilities.manager
            let output = session.capabilities.output
            try await manager.register(speech, sessionID: id)
            try await speech.start()
            let consumer = try await output.consumer(for: speech)
            outputTask = Task {
                do {
                    try await IndependentOutputWorkflow.consumeSignals(speech.outputs) { envelope in
                        try Task.checkCancellation()
                        try await consumer.execute(envelope)
                    }
                    if !closing, await speech.status().lifecycle == .failed {
                        await fail(AudioDetectionError.perceptionFailed)
                    }
                } catch is CancellationError {} catch { await fail(error) }
            }
        }
        private func observe(_ input: AgentInput) {
            guard !closing, input.sessionID == id, !input.metadata.expired,
                let observation = input.payload.perception, case .soundSource(let value) = observation
            else { return }
            let state: AudioDetectionSnapshot.Direction
            switch value.state {
            case .active: state = .active
            case .inactive: state = .inactive
            case .uncertain: state = .uncertain
            case .unavailable: state = .unavailable
            }
            observe(.direction(state, value.direction?.azimuth, value.direction?.elevation, input.metadata.deadline))
        }
        private func stop() async throws {
            closing = true
            outputTask?.cancel()
            await speech.stop()
            await outputTask?.value
            outputTask = nil
            if let session { try await gateway.close(session) }
            session = nil
        }
    }
#endif
