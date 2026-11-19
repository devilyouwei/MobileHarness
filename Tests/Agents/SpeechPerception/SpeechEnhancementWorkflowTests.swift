import AgentCore
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
    init(_ recorder: EnhancedPCMRecorder, silenceAfter: Int64? = nil) {
        self.recorder = recorder
        self.silenceAfter = silenceAfter
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
            try VoiceActivityScore(
                startSample: position + Int64(offset), sampleCount: min(512, frame.sampleCount - offset),
                probability: silenceAfter.map { position + Int64(offset) < $0 ? Float(1) : Float(0) } ?? 1)
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
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context,
            limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        return SpeechRecognitionSession(
            output: pair.session, format: request.format,
            sendAudio: { await recorder.record($0) },
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

@Test(.actionCatalog) func speechWorkflowPlaybackStartAdmitsPCMImmediately() async throws {
    let vad = EnhancedPCMRecorder()
    let asr = EnhancedPCMRecorder()
    let session = UUID().uuidString
    let origin = ContinuousClock.now
    var history = SpeechPlaybackHistory()
    history.started(id: "reply", sessionID: session, at: origin)
    let snapshot = history.read(sessionID: session)
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: asr), vad: EnhancementVADFixture(vad), sessionID: session,
        speechPlayback: { snapshot }, speechDetection: { (1, 0.65) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await agent.start()
    for index in 0..<12 {
        try await agent.processMicrophone(
            MicrophoneFrame(
                samples: [Float](repeating: 0.25, count: 512), sampleRate: 16000, sequence: UInt64(index),
                timestamp: Double(index) * 0.032, capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: session)
        if index == 0 { #expect(await vad.count == 512) }
    }
    #expect(await vad.count == 12 * 512)
    let deadline = ContinuousClock.now + .seconds(2)
    while await asr.count < 12 * 512, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await asr.count == 12 * 512)
    await agent.stop()
}

@Test(.actionCatalog) func speechWorkflowModelChunkPreservesContinuousSpeech() async throws {
    let vad = EnhancedPCMRecorder()
    let asr = EnhancedPCMRecorder()
    let session = UUID().uuidString
    let origin = ContinuousClock.now
    let agent = try SpeechPerceptionAgent(
        recognition: EnhancementASRFixture(recorder: asr), vad: EnhancementVADFixture(vad), sessionID: session,
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
