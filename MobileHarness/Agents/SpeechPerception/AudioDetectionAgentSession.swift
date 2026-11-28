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
        private let keywordTest: SpeechKeywordTest?
        private let observe: @MainActor (AudioDetectionObservation) -> Void
        private var outputTask: Task<Void, Never>?
        private var closing = false
        init(
            gateway: AgentObservationAccess, id: String, recognition: any SpeechRecognitionCapability,
            vad: any VoiceActivityCapability,
            input nativeInput: any AudioCaptureObserving,
            keywordTest: SpeechKeywordTest? = nil,
            enhancement: (any SpeechEnhancementCapability)? = nil,
            enhancementEnabled: @escaping @Sendable () async throws -> Bool = { false },
            observe: @escaping @MainActor (AudioDetectionObservation) -> Void
        ) throws {
            self.gateway = gateway
            self.id = id
            self.observe = observe
            self.keywordTest = keywordTest
            let configuration = try AgentConfigurations.load(named: "SpeechPerception").restrictingCommunication(
                to: ["perception.audio.source.v1"], contracts: AgentContracts.communication)
            policy = try CommunicationPolicy(contracts: AgentContracts.communication, configurations: [configuration])
            let keywordAudio: (@Sendable ([Float]) async throws -> Void)?
            if let keywordTest {
                keywordAudio = { samples in
                    let update = try await keywordTest.accept(samples)
                    if let audio = update.audio {
                        await observe(.keywordAudio(samples: audio.samples, rms: audio.rms))
                    }
                    if let hit = update.hit {
                        await observe(.keyword(phrase: hit.phrase, silentTail: hit.silentTail))
                    }
                }
            } else {
                keywordAudio = nil
            }
            speech = try SpeechPerceptionAgent(
                recognition: recognition, vad: vad, enhancement: enhancement,
                speechEnhancementEnabled: enhancementEnabled, sessionID: id, configuration: configuration,
                mode: keywordTest == nil ? .soundSourceOnly : .keywordTest,
                microphoneInput: nativeInput,
                microphoneObservation: { observe(.microphone($0.layout, $0.sampleRate, $0.rms, $0.capturedAt)) },
                keywordTestAudio: keywordAudio,
                context: AgentContextRepository(
                    agent: .speechPerception, scope: "00000000-0000-0000-0000-000000000002",
                    state: SpeechPerceptionContextState()))
        }
        static func connections(
            recognition: any SpeechRecognitionCapability, vad: any VoiceActivityCapability,
            keywordSpotting: (any KeywordSpottingCapability)? = nil,
            keywordThreshold: @escaping @Sendable () async throws -> Double = { 0.25 },
            enhancement: (any SpeechEnhancementCapability)? = nil,
            enhancementEnabled: @escaping @Sendable () async throws -> Bool = { false },
            gateway: AgentObservationAccess
        ) -> AudioDetectionConnections {
            let makeKeywordPerception: AudioDetectionConnections.MakePerception = { id, input, observe, fail in
                let lexicon = try SpeechKeywordLexicon.load()
                let keywords = lexicon.keywords(threshold: Float(try await keywordThreshold()))
                let open: @Sendable () async throws -> any KeywordSpottingSession = {
                    guard let session = try await keywordSpotting?.openKeywords(keywords) else {
                        throw AudioDetectionError.keywordModelNotReady
                    }
                    return session
                }
                let test = SpeechKeywordTest(session: try await open(), lexicon: lexicon, reopen: open)
                do {
                    let owner = try AudioDetectionAgentSession(
                        gateway: gateway, id: id, recognition: recognition, vad: vad, input: input,
                        keywordTest: test, enhancement: enhancement, enhancementEnabled: enhancementEnabled,
                        observe: observe)
                    return try await owner.connect(fail: fail)
                } catch {
                    await test.stop()
                    throw error
                }
            }
            return AudioDetectionConnections(makeKeywordPerception: makeKeywordPerception) { id, input, observe, fail in
                let owner = try AudioDetectionAgentSession(
                    gateway: gateway, id: id, recognition: recognition, vad: vad, input: input, observe: observe)
                return try await owner.connect(fail: fail)
            }
        }
        private func connect(fail: @escaping @MainActor (any Error) async -> Void) async throws
            -> AudioDetectionPerception
        {
            do {
                try await start(fail: fail)
                return AudioDetectionPerception(
                    perception: speech,
                    stop: { [self] in do { try await stop() } catch { await fail(error) } })
            } catch {
                let primary = error
                do { try await stop() } catch {
                    throw AgentFailure(
                        component: "detection", operation: "start", underlying: primary, cleanupErrors: [error])
                }
                throw primary
            }
        }
        private func start(fail: @escaping @MainActor (any Error) async -> Void) async throws {
            let session = try gateway.open(
                policy: policy, observedContracts: ["perception.audio.source.v1"],
                observeEvent: { [weak self] in await self?.observe($0) })
            self.session = session
            let manager = session.capabilities.manager
            let output = session.capabilities.output
            try await manager.register(speech, sessionID: id)
            try await speech.start()
            let consumer = try await output.consumer(for: speech)
            outputTask = Task {
                do {
                    try await IndependentOutputWorkflow.consumeSignals(
                        speech.outputs, publicationChannels: speech.descriptor.publicationChannels
                    ) { envelope in
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
            await keywordTest?.stop()
            await outputTask?.value
            outputTask = nil
            if let session { try await gateway.close(session) }
            session = nil
        }
    }
#endif
