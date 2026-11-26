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
func speechWorkflowAppliesNativePlaybackAtPCMCaptureTime() async throws {
    let vad = EnhancedPCMRecorder()
    let asr = EnhancedPCMRecorder()
    let session = UUID().uuidString
    let origin = ContinuousClock.now
    let microphone = NativeMicrophoneFixture()
    await microphone.setPlayback(.init(periods: [.init(start: origin)]))
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: asr),
        vad: EnhancementVADFixture(vad, voicedProbability: 0.7), sessionID: session,
        interactionSessionID: session, residentListening: true, microphoneInput: microphone,
        speechDetection: { (1, 0.65) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await agent.start()
    _ = try await agent.setListening(enabled: true, sessionID: session)
    try await agent.openCapture(sessionID: session)

    func send(_ index: Int) async throws {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0.25, count: 512), sampleRate: 16000, sequence: UInt64(index),
                timestamp: Double(index) * 0.032, capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: session)
    }
    try await send(0)
    #expect(await vad.count == 512)

    await microphone.setPlayback(.init(periods: [.init(start: origin, end: origin + .milliseconds(96))]))
    for index in 1..<10 { try await send(index) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await asr.count == 0)

    // Buffered PCM captured after the playback tail uses the base gate.
    for index in 10..<14 { try await send(index) }
    #expect(await vad.count == 14 * 512)
    let deadline = ContinuousClock.now + .seconds(2)
    while await asr.count == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await asr.count > 0)
    await agent.stop()
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
    let pump = Task { for await _ in fixtureOutputs(agent) {} }
    func send(_ index: Int) async throws {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0, count: 512), sampleRate: 16000, sequence: UInt64(index),
                timestamp: Double(index) * 0.032, capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: session)
    }
    func proof() -> [SpeechActivity] {
        activities.withLock { $0.filter { $0.kind == .vadProgress && $0.oldestWindow != nil } }
    }
    for index in 0..<64 { try await send(index) }
    for _ in 0..<200 where proof().count < 1 { try await Task.sleep(for: .milliseconds(2)) }
    let first = try #require(proof().first)
    #expect(first.sequence == 64 && first.oldestWindow == SpeechSignalClock.offset(at: origin))
    await agent.endVADCapture()
    await agent.beginVADCapture()
    for index in 64..<127 { try await send(index) }
    #expect(proof().count == 1)
    try await send(127)
    for _ in 0..<200 where proof().count < 2 { try await Task.sleep(for: .milliseconds(2)) }
    let second = try #require(proof().last)
    #expect(second.generation != first.generation)
    #expect(second.sequence == 64 && second.oldestWindow == SpeechSignalClock.offset(at: origin + .milliseconds(2048)))
    await agent.stop()
    await pump.value
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
