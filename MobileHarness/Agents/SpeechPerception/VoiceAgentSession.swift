#if os(iOS)
    import Actions
    import AgentCore
    import Foundation
    import Gateway
    import ModelKit
    import PlatformKit
    import StorageCache

    /// Immutable service slices; session owners cannot reach unrelated application facilities.
    @MainActor
    struct VoiceRuntimeDependencies {
        let cache: CacheContainer
        let manager: AgentManager
        let output: OutputGateway
        let endpoints: ActionEndpoints
        let interactionSessionID: String
        let startInteraction: @MainActor () async throws -> Void
        let cancelReply: @MainActor () async throws -> Void
        let stopInteraction: @MainActor () async -> Void
        let makeSynthesis: (any SpeechSynthesisCapability, AudioCache) throws -> SpeechSynthesisAgent
        let makePerception:
            (
                any SpeechRecognitionCapability, any VoiceActivityCapability, String, any AudioCaptureObserving,
                MicrophoneSpectrumPresentation
            ) throws
                -> SpeechPerceptionAgent
    }

    /// Owns actual role registration and bound output work. No device control or UI mutation.
    @MainActor final class VoiceAgentSession {
        private let runtime: VoiceRuntimeDependencies
        private let spectrum: MicrophoneSpectrumPresentation
        private var speech: SpeechPerceptionAgent?
        private var outputTask: Task<Void, Never>?
        init(runtime: VoiceRuntimeDependencies, spectrum: MicrophoneSpectrumPresentation) {
            self.runtime = runtime
            self.spectrum = spectrum
        }
        var connections: VoiceSessionConnections {
            VoiceSessionConnections(
                endpoints: runtime.endpoints, interactionSessionID: runtime.interactionSessionID,
                cancelReply: runtime.cancelReply, adaptFailure: SpeechPlaybackFailure.adapting)
        }
        var sessionID: String { runtime.interactionSessionID }
        func audioStore() async throws -> AudioCache {
            try await runtime.cache.audioScope(runtime.interactionSessionID)
        }
        func startInteraction() async throws { try await runtime.startInteraction() }
        func start(
            _ recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
            synthesis: any SpeechSynthesisCapability, input: any AudioCaptureObserving, store: AudioCache,
            report: @escaping @MainActor (String) -> Void
        ) async throws -> any VoicePerceptionHandling {
            guard speech == nil else { throw CapabilityError.inputBusy }
            let synthesizer = try runtime.makeSynthesis(synthesis, store)
            try await runtime.manager.register(synthesizer)
            try await runtime.manager.start(synthesizer.descriptor.id)
            let speech = try runtime.makePerception(recognition, vad, runtime.interactionSessionID, input, spectrum)
            try await runtime.manager.register(speech)
            self.speech = speech
            try await runtime.manager.start(.speechPerception)
            let consumer = try await runtime.output.consumer(for: speech)
            outputTask = Task {
                do {
                    try await IndependentOutputWorkflow.consumeSignals(speech.outputs) { @MainActor output in
                        do { try await consumer.execute(output) } catch is CancellationError {
                            throw CancellationError()
                        } catch { report("输出失败：\(error)") }
                    }
                } catch is CancellationError {} catch { report("语音输出消费失败：\(error)") }
            }
            return speech
        }
        func stop() async {
            await speech?.stop()
            outputTask?.cancel()
            await outputTask?.value
            outputTask = nil
            speech = nil
            try? await runtime.manager.remove(.speechPerception)
            await runtime.stopInteraction()
            try? await runtime.manager.remove(AgentID(rawValue: "speechSynthesis"))
            await runtime.cache.closeAudioScope(runtime.interactionSessionID)
        }
    }
#endif
