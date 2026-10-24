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
        let reportFailure: @Sendable (String, String, any Error) -> Void
        let interactionSessionID: String
        let startInteraction: @MainActor () async throws -> Void
        let cancelReply: @MainActor () async throws -> Void
        let makeSynthesis: (any SpeechSynthesisCapability, AudioCache) throws -> SpeechSynthesisAgent
        let makePerception:
            (
                any SpeechRecognitionCapability, any VoiceActivityCapability, String, any AudioCaptureObserving,
                MicrophoneSpectrumPresentation
            ) throws
                -> SpeechPerceptionAgent
    }

    /// Connection adapter only. Role containers independently own registration and output lifetime.
    @available(iOS 27, *)
    @MainActor final class VoiceAgentSession {
        private let runtime: VoiceRuntimeDependencies
        private let spectrum: MicrophoneSpectrumPresentation
        private unowned let perception: SpeechPerceptionContainer
        private unowned let synthesis: SpeechSynthesisContainer
        init(
            runtime: VoiceRuntimeDependencies, spectrum: MicrophoneSpectrumPresentation,
            perception: SpeechPerceptionContainer, synthesis: SpeechSynthesisContainer
        ) {
            self.runtime = runtime
            self.spectrum = spectrum
            self.perception = perception
            self.synthesis = synthesis
        }
        var connections: VoiceSessionConnections {
            VoiceSessionConnections(
                endpoints: runtime.endpoints, interactionSessionID: runtime.interactionSessionID,
                cancelReply: runtime.cancelReply, adaptFailure: SpeechPlaybackFailure.adapting)
        }
        func audioStore() async throws -> AudioCache {
            try await runtime.cache.audioScope(runtime.interactionSessionID)
        }
        func startInteraction() async throws { try await runtime.startInteraction() }
        func start(
            _ recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
            synthesis capability: any SpeechSynthesisCapability, input: any AudioCaptureObserving, store: AudioCache
        ) async throws -> any VoicePerceptionHandling {
            try await synthesis.start(synthesis: capability, store: store, runtime: runtime)
            return try await perception.start(
                recognition: recognition, vad: vad, input: input,
                spectrum: spectrum, runtime: runtime)
        }
        func stop() async throws {
            var errors: [any Error] = []
            do { try await perception.endSession() } catch { errors.append(error) }
            do { try await synthesis.endSession() } catch { errors.append(error) }
            await runtime.cache.closeAudioScope(runtime.interactionSessionID)
            if let primary = errors.first {
                throw AgentFailure(
                    component: "speech", operation: "stop", underlying: primary,
                    cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
            }
        }
    }
#endif
