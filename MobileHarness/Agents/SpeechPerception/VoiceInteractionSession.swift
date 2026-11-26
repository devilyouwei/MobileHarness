#if os(iOS)

    import FunctionContracts
    import Foundation
    import ModelKit
    import ModelKitDefaults
    import ModelKitRuntime
    import PlatformKit
    import UI

    /// Resolves default capabilities once; consumers receive shared, managed capability instances.
    @MainActor
    @available(iOS 27, *)
    final class VoiceInteractionSession {
        private var starting: Task<Void, any Error>?
        private var started = false
        private let voiceAgents: VoiceAgentSession
        private let stopDiagnostic: @MainActor () async throws -> Void
        private let recognition: any SpeechRecognitionCapability
        private let enhancement: any SpeechEnhancementCapability
        private let endpointConfirmation: (any SpeechEndpointCapability)?
        private let keywordSpotting: (any KeywordSpottingCapability)?
        private let vad: any VoiceActivityCapability
        private let synthesis: any SpeechSynthesisCapability
        private let voiceInput: any AudioCaptureObserving
        public let listeningRequests: UIRequests<ListeningInput, Void>
        func startInteraction() async throws {
            if started { return }
            if let starting { return try await starting.value }
            let task = Task { [self] in
                do {
                    let store = try await voiceAgents.audioStore()
                    let perception = try await voiceAgents.start(
                        recognition, vad: vad, enhancement: enhancement, keywordSpotting: keywordSpotting,
                        endpointConfirmation: endpointConfirmation, synthesis: synthesis,
                        input: voiceInput, store: store)
                    try Task.checkCancellation()
                    try await lifecycle.start(perception: perception, audioStore: store)
                    try await voiceAgents.startInteraction()
                    started = true
                } catch {
                    let primary = error
                    await lifecycle.shutdown()
                    do { try await voiceAgents.stop() } catch {
                        throw AgentFailure(
                            component: "speech", operation: "start", underlying: primary,
                            cleanupErrors: [error])
                    }
                    throw primary
                }
            }
            starting = task
            defer { starting = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        func invalidateStartup() { starting?.cancel() }
        func suspend() async {
            _ = await starting?.result
            await detectionInvalidation?.value
            await audioDetection.stopAndWait()
            await lifecycle.stopVoiceAndWait()
        }
        func shutdown() async throws {
            starting?.cancel()
            _ = await starting?.result
            var cleanupErrors: [any Error] = []
            await detectionInvalidation?.value
            await audioDetection.stopAndWait()
            await lifecycle.stopVoiceAndWait()
            do { try await voiceAgents.stop() } catch { cleanupErrors.append(error) }
            started = false
            do { try await stopDiagnostic() } catch { cleanupErrors.append(error) }
            if !cleanupErrors.isEmpty { throw NativeCleanupFailure(errors: cleanupErrors) }
        }
        let lifecycle: any AgentVoiceLifecycle
        public let conversation: ConversationState
        public let diagnostic: any SpeechDiagnosticControlling
        public let diagnosticState: SpeechDiagnosticState
        public let audioDetectionState: AudioDetectionState
        let audioDetection: any AgentDetectionControl
        public let detectionRequests: UIRequests<AudioDetectionInput, Void>

        private var detectionInvalidation: Task<Void, Never>?
        func invalidateDetection() {
            guard detectionInvalidation == nil else { return }
            detectionInvalidation = Task { [self] in
                await audioDetection.stopAndWait()
                detectionInvalidation = nil
            }
        }
        #if DEBUG
            public let validateVoiceModels: @Sendable () async throws -> String
        #endif

        init(
            home: UIHomeContainer, diagnostics: UIDiagnosticsContainer,
            language: any ModelLanguageProviding, speech: any ModelSpeechProviding,
            audio: AudioContainer, runtime: AgentRuntime,
            perceptionContainer: SpeechPerceptionContainer,
            progress: @MainActor (String) -> Void
        ) async throws {
            audioDetectionState = diagnostics.audioDetection
            let recognition = speech.recognition
            let chat = language
            let vad = speech.voiceActivity
            let synthesis = speech.synthesis
            self.recognition = recognition
            self.enhancement = speech.enhancement
            self.keywordSpotting = speech.keywordSpotting
            self.endpointConfirmation = speech.endpointConfirmation
            self.vad = vad
            self.synthesis = synthesis
            voiceInput = audio.io(.voice)
            listeningRequests = home.listeningRequests
            let diagnosticState = diagnostics.speech
            self.diagnosticState = diagnosticState
            // Preparation is deferred to explicit voice admission; missing downloads do not block Settings/history.
            progress("Download local models in Settings")
            try Task.checkCancellation()
            let state = home.conversation
            let native = try runtime.business.makeVoice(
                AgentVoiceHost(
                    sessionID: runtime.interactionSessionID,
                    cancelReply: runtime.voiceDependencies.cancelReply,
                    detection: AudioDetectionAgentSession.connections(
                        recognition: recognition, vad: vad, keywordSpotting: speech.keywordSpotting,
                        keywordThreshold: { [settings = runtime.business.keywordDetection] in
                            try await settings().threshold
                        },
                        enhancement: speech.enhancement, enhancementEnabled: runtime.business.speechEnhancementEnabled,
                        gateway: runtime.observations),
                    preparePlayback: runtime.voiceDependencies.preparePlayback,
                    playbackChanged: runtime.voiceDependencies.playbackChanged))
            let spectrum = native.spectrum
            diagnostic = native.diagnostic
            stopDiagnostic = native.stopDiagnostic
            #if DEBUG
                validateVoiceModels = native.validate
            #endif
            let voiceAgents = VoiceAgentSession(
                runtime: runtime.voiceDependencies, spectrum: spectrum,
                perception: perceptionContainer)
            self.voiceAgents = voiceAgents
            self.lifecycle = native.lifecycle
            self.audioDetection = native.detection
            detectionRequests = diagnostics.detectionRequests
            conversation = state
        }
    }

#endif
