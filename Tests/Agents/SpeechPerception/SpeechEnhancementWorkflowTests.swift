import AgentCore
import CallRuntime
import Foundation
import ModelKit
import StorageCore
import Synchronization
import Testing

@testable import Agents
@testable import PlatformKit

private actor EnhancedPCMRecorder {
    var finishes = 0
    func finish() { finishes += 1 }
    var count = 0
    var maximum: Float = 0
    func record(_ frame: AudioFrame) {
        count += frame.sampleCount
        let peak = frame.data.withUnsafeBytes { bytes in
            (0..<frame.sampleCount).reduce(Float(0)) {
                max($0, abs(bytes.loadUnaligned(fromByteOffset: $1 * 4, as: Float.self)))
            }
        }
        maximum = max(maximum, peak)
    }
}
private actor ZeroEnhancementFixture: SpeechEnhancementCapability {
    var availability: CapabilityAvailability { .available }
    var sizes: [Int] = []
    func enhance(_ audio: AudioFrame) async throws -> AudioFrame {
        sizes.append(audio.sampleCount)
        return try AudioFrame(
            data: Data(repeating: 0, count: audio.data.count), format: audio.format,
            sequence: audio.sequence, timestamp: audio.timestamp)
    }
}
private actor EnhancementVADFixture: VoiceActivityCapability, VoiceActivitySession {
    let recorder: EnhancedPCMRecorder
    var position: Int64 = 0
    private var lastSequence: UInt64?
    let silenceAfter: Int64?
    let voicedProbability: Float
    init(_ recorder: EnhancedPCMRecorder, silenceAfter: Int64? = nil, voicedProbability: Float = 1) {
        self.recorder = recorder
        self.silenceAfter = silenceAfter
        self.voicedProbability = voicedProbability
    }
    var availability: CapabilityAvailability { .available }
    func detectVoiceActivity(format: AudioFormat) -> any VoiceActivitySession { self }
    func process(_ frame: AudioFrame) async throws -> [VoiceActivityScore] {
        guard lastSequence.map({ frame.sequence > $0 }) ?? true else {
            throw CapabilityError.invalidRequest("VAD frames must have strictly increasing sequence")
        }
        lastSequence = frame.sequence
        await recorder.record(frame)
        defer { position += Int64(frame.sampleCount) }
        return try stride(from: 0, to: frame.sampleCount, by: 512).map { offset in
            let voiced = silenceAfter.map { position + Int64(offset) < $0 } ?? true
            return try VoiceActivityScore(
                startSample: position + Int64(offset), sampleCount: min(512, frame.sampleCount - offset),
                probability: voiced ? voicedProbability : 0)
        }
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() {
        position = 0
        lastSequence = nil
    }
    func cancel() {}
}
private struct EnhancementASRFixture: SpeechRecognitionCapability {
    let recorder: EnhancedPCMRecorder
    var emitsPreview = false
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context,
            limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        let sentPreview = Mutex(false)
        return SpeechRecognitionSession(
            output: pair.session, format: request.format,
            sendAudio: { frame in
                await recorder.record(frame)
                if emitsPreview,
                    sentPreview.withLock({ emitted in
                        guard !emitted else { return false }
                        emitted = true
                        return true
                    })
                {
                    try pair.emitter.yield(
                        TranscriptionEvent(segmentID: "preview", revision: 0, text: "speech", isFinal: false))
                }
            },
            finishInput: {
                await recorder.finish()
                pair.emitter.finish()
            })
    }
}

@Test(.actionCatalog, arguments: [false, true])
func speechEnhancementWorkflowFeedsBothVADAndASR(enabled: Bool) async throws {
    let vad = EnhancedPCMRecorder()
    let asr = EnhancedPCMRecorder()
    let session = UUID().uuidString
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: asr),
        vad: EnhancementVADFixture(vad), enhancement: ZeroEnhancementFixture(),
        speechEnhancementEnabled: { enabled }, sessionID: session, speechDetection: { (1, 0.5) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await agent.start()
    try await agent.configureEnhancement()
    for index in 0..<10 {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0.25, count: 4000),
                sampleRate: 48000, sequence: UInt64(index), timestamp: Double(index * 4000) / 48000),
            sessionID: session, captureGeneration: session)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await asr.count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await vad.count > 0)
    #expect(await asr.count > 0)
    if enabled {
        #expect(await vad.maximum == 0)
        #expect(await asr.maximum == 0)
    } else {
        #expect(await vad.maximum > 0.2)
        #expect(await asr.maximum > 0.2)
    }
    await agent.stop()
}

@Test(.actionCatalog) func speechEnhancementResetsHistoryAtUtteranceCompletion() async throws {
    let vad = EnhancedPCMRecorder()
    let asr = EnhancedPCMRecorder()
    let enhancement = ZeroEnhancementFixture()
    let session = UUID().uuidString
    let origin = ContinuousClock.now
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: asr),
        vad: EnhancementVADFixture(vad, silenceAfter: 4096), enhancement: enhancement,
        speechEnhancementEnabled: { true }, sessionID: session,
        speechDetection: { (1, 0.5) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await agent.start()
    try await agent.configureEnhancement()
    for index in 0..<48 {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0.25, count: 4000),
                sampleRate: 48000, sequence: UInt64(index), timestamp: Double(index * 4000) / 48000,
                capturedAt: origin + .seconds(Double(index * 4000) / 48000)),
            sessionID: session, captureGeneration: session)
    }
    #expect(await asr.finishes > 0)
    let sizes = await enhancement.sizes
    #expect(sizes.filter { $0 == 19200 }.count >= 2)
    #expect(sizes.first == 19200)
    #expect(sizes.allSatisfy { $0 == 19200 || $0 == 34560 })
    await agent.stop()
}

@Test(.actionCatalog) func speechWorkflowAdmitsImmediateAudioAfterEmptyASR() async throws {
    let vad = EnhancedPCMRecorder()
    let asr = EnhancedPCMRecorder()
    let session = UUID().uuidString
    let origin = ContinuousClock.now
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: asr), vad: EnhancementVADFixture(vad, silenceAfter: 512),
        sessionID: session, speechDetection: { (1, 0.5) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await agent.start()
    func send(_ index: Int) async throws {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0.25, count: 512), sampleRate: 16000, sequence: UInt64(index),
                timestamp: Double(index) * 0.032, capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: session)
    }
    for index in 0..<26 { try await send(index) }
    #expect(await asr.finishes == 1)
    let before = await vad.count
    for index in 26..<34 { try await send(index) }
    #expect(await vad.count == before + 8 * 512)
    try await send(34)
    #expect(await vad.count == before + 9 * 512)
    // Replacing the capture generation remains supported.
    await agent.bindMicrophoneGeneration("replacement")
    await agent.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func speechWorkflowAppliesGatewayPlaybackAtPCMCaptureTime() async throws {
    let vad = EnhancedPCMRecorder()
    let asr = EnhancedPCMRecorder()
    let session = UUID().uuidString
    let origin = ContinuousClock.now
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let output = await OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let producer = SpeechRequestProbe()
    let assistant = try AssistantAgent(
        stateContext: publicStateFixture(), speechOutput: producer, speechSessionID: session, chat: FixedTextChat(),
        context: AgentContextRepository(agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()))
    var history = SpeechPlaybackHistory()
    history.started(id: "reply", sessionID: session, at: origin)
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: asr),
        vad: EnhancementVADFixture(vad, voicedProbability: 0.7), sessionID: session,
        interactionSessionID: session, residentListening: true, speechDetection: { (1, 0.65) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    for role in [assistant as any Agent, agent] {
        try await manager.register(role, sessionID: session)
        try await manager.start(role.descriptor.id)
        _ = try await output.consumer(for: role)
    }
    _ = try await agent.setListening(enabled: true, sessionID: session)
    try await agent.openCapture(sessionID: session)
    await producer.setPlaying(true)
    await producer.setPlaybackSnapshot(history.read(sessionID: session))
    await assistant.refreshReplyActivity()
    await input.flushPublications()
    #expect(await agent.replyActive)

    func send(_ index: Int) async throws {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0.25, count: 512), sampleRate: 16000, sequence: UInt64(index),
                timestamp: Double(index) * 0.032, capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: session)
    }
    try await send(0)
    #expect(await vad.count == 512)

    // The reply stays active, but the stopped interval must still be republished.
    history.ended(id: "reply", at: origin + .milliseconds(96))
    await producer.setPlaybackSnapshot(history.read(sessionID: session))
    await assistant.refreshReplyActivity()
    await input.flushPublications()
    for index in 1..<10 { try await send(index) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await asr.count == 0)

    // PCM captured after the playback tail uses the base gate even while the reply remains active.
    for index in 10..<14 { try await send(index) }
    #expect(await vad.count == 14 * 512)
    let deadline = ContinuousClock.now + .seconds(2)
    while await asr.count == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await asr.count > 0)
    #expect(await agent.replyActive)
    await manager.stopAll()
    await output.shutdown()
}

@Test(.actionCatalog) func speechContinuationCountsOnlyScoredWindowsInCurrentCapture() async throws {
    let session = UUID().uuidString
    let origin = ContinuousClock.now
    let activities = Mutex([SpeechActivity]())
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: EnhancedPCMRecorder()),
        vad: EnhancementVADFixture(EnhancedPCMRecorder(), voicedProbability: 0), sessionID: session,
        interactionSessionID: session, residentListening: true,
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await agent.bind(
        AgentMessaging { message, _, _ in
            if let activity = message.content(as: SpeechActivity.self) {
                activities.withLock { $0.append(activity) }
            }
            return DeliveryReport()
        })
    try await agent.start()
    _ = try await agent.setListening(enabled: true, sessionID: session)
    try await agent.openCapture(sessionID: session)
    await agent.publishSpeech(SpeechActivity(.captureStarted, generation: "old"))
    let probe = SpeechContinuationProbe(since: origin + .milliseconds(32))
    let payload = InputPayload.observation(ReplyActivitySignal(active: false, continuation: probe).message())
    try await agent.receive(
        .init(
            id: "accepted-interrupt", sessionID: session, payload: payload,
            metadata: .init(
                payload: payload, source: AgentID.assistant.rawValue, incarnation: "fixture", origin: .agent,
                rootID: "accepted-interrupt", topic: ReplyActivitySignal.channel)))
    func send(_ index: Int) async throws {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0, count: 512), sampleRate: 16000, sequence: UInt64(index),
                timestamp: Double(index) * 0.032, capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: session)
    }
    func readiness() -> [SpeechActivity] { activities.withLock { $0.filter { $0.kind == .continuationReady } } }

    #expect(SpeechContinuationProbe.windowCount == 64)
    for index in 0..<64 { try await send(index) }
    #expect(readiness().isEmpty)
    await agent.publishSpeech(SpeechActivity(.captureStopped, generation: "old"))
    await agent.publishSpeech(SpeechActivity(.captureStarted, generation: "recovered"))
    for index in 64..<127 { try await send(index) }
    #expect(readiness().isEmpty)
    let ready = SpeechActivity(.continuationReady, generation: "recovered", continuation: probe)
    try await send(127)
    #expect(readiness() == [ready])
    try await send(128)
    #expect(readiness() == [ready])
    await agent.stop()
}

@Test(.actionCatalog) func speechWorkflowModelChunkPreservesContinuousSpeech() async throws {
    let vad = EnhancedPCMRecorder()
    let asr = EnhancedPCMRecorder()
    let session = UUID().uuidString
    let origin = ContinuousClock.now
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: asr, emitsPreview: true),
        vad: EnhancementVADFixture(vad), sessionID: session,
        speechDetection: { (1, 0.5) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await agent.start()
    for index in 0..<380 {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0.25, count: 512), sampleRate: 16000, sequence: UInt64(index),
                timestamp: Double(index) * 0.032, capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: session)
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while await asr.count < 380 * 512, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await asr.finishes == 1)
    #expect(await asr.count == 380 * 512)
    await agent.stop()
}
