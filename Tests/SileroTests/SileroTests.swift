import AVFAudio
import Foundation
@_spi(ModelManagement) import ModelKit
import ModelKitNemotron
import ModelKitSilero
import PlatformKit
import Testing

@testable import Agents

private let format = try! AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
private func pcm(_ samples: [Float], sequence: UInt64) throws -> AudioFrame {
    try AudioFrame(data: samples.withUnsafeBytes { Data($0) }, format: format, sequence: sequence, timestamp: 0)
}

private struct RecordedSegment {
    let frames: [AudioFrame]
    let reason: VoiceSegmentEnd
}

private struct BoundaryRecorder {
    private var policy = SpeechBoundaryPolicy()
    private var frames: [AudioFrame] = []
    var isSpeaking: Bool { policy.isSpeaking }
    var streamEvents: [VoiceStreamEvent] { policy.streamEvents }
    mutating func consume(_ frame: AudioFrame, probability: Float, threshold: Float) -> RecordedSegment? {
        _ = policy.consume(frame, probability: probability, threshold: threshold)
        var completed: RecordedSegment?
        for event in policy.streamEvents {
            switch event {
            case .audio(let audio): frames += audio
            case .end(let reason):
                completed = RecordedSegment(frames: frames, reason: reason)
                frames.removeAll()
            }
        }
        return completed
    }
    mutating func finish() -> RecordedSegment? {
        guard policy.isSpeaking else { return nil }
        let result = RecordedSegment(frames: frames + policy.uncommittedFrames, reason: .inputFinished)
        frames.removeAll()
        policy.reset()
        return result
    }
}

@Test func speechBoundariesUseConsecutiveProbabilityNotAmplitude() throws {
    var policy = BoundaryRecorder()
    let frame = try pcm(Array(repeating: 0, count: 512), sequence: 0)
    for _ in 0..<2 { #expect(policy.consume(frame, probability: 0.9, threshold: 0.5) == nil) }
    #expect(!policy.isSpeaking)
    _ = policy.consume(frame, probability: 0.1, threshold: 0.5)
    for _ in 0..<3 { _ = policy.consume(frame, probability: 0.9, threshold: 0.5) }
    #expect(policy.isSpeaking)
    for _ in 0..<24 { #expect(policy.consume(frame, probability: 0.1, threshold: 0.5) == nil) }
    let utterance = policy.consume(frame, probability: 0.1, threshold: 0.5)
    #expect(utterance != nil)
    #expect(!policy.isSpeaking)
    #expect(utterance!.frames.reduce(0) { $0 + $1.duration } <= 1.1)
}

@Test func speechBoundariesLimitContinuousSpeech() throws {
    var policy = BoundaryRecorder()
    let frame = try pcm(Array(repeating: 0, count: 512), sequence: 0)
    var completed: RecordedSegment?
    for _ in 0..<380 {
        if let value = policy.consume(frame, probability: 0.9, threshold: 0.5) {
            completed = value
            break
        }
    }
    #expect(completed != nil)
    #expect(completed!.frames.reduce(0) { $0 + $1.duration } <= 12.04)
}

@Test func streamingResamplerPreservesFilterHistory() async throws {
    for rate in [16000, 44100, 48000] {
        let resampler = StreamingMonoPCMResampler()
        let samples = (0..<rate).map { Float(sin(2 * Double.pi * 440 * Double($0) / Double(rate))) * 0.2 }
        var converted: [Float] = []
        for offset in stride(from: 0, to: rate, by: 1024) {
            let frames = try await resampler.process(
                MicrophoneFrame(
                    samples: Array(samples[offset..<min(offset + 1024, rate)]), sampleRate: rate,
                    sequence: UInt64(offset)))
            converted.append(contentsOf: frames.flatMap(\.samples))
        }
        #expect(abs(converted.count - 16000) < 128)
        #expect(converted.allSatisfy { $0.isFinite })
        let crossings = zip(converted, converted.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        #expect(abs(crossings - 440) < 3)
        await resampler.reset()
        let first = try await resampler.process(
            MicrophoneFrame(samples: Array(samples.prefix(1024)), sampleRate: rate, sequence: 0))
        #expect(Array(converted.prefix(first.flatMap(\.samples).count)) == first.flatMap(\.samples))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_SILERO"] == "1"))
func realSileroStreamingResetTailAndSilence() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let models = repo.appendingPathComponent("MobileHarness/Resources/Models")
    let providerContext = ModelContext()
    let provider = try SileroVAD(
        context: providerContext,
        artifacts: models.appendingPathComponent("Silero"))
    try await providerContext.load()
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: "/tmp/nemotron-fixture.wav"))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    #expect(file.processingFormat.sampleRate == 16000)
    let speech = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let samples = [Float](repeating: 0, count: 16000) + speech + [Float](repeating: 0, count: 16000)
    var baseline: [VoiceActivityScore] = []
    for packet in [512, 137, 4000] {
        let session = try await provider.detectVoiceActivity(format: format)
        var scores: [VoiceActivityScore] = []
        for offset in stride(from: 0, to: samples.count, by: packet) {
            scores += try await session.process(
                pcm(Array(samples[offset..<min(offset + packet, samples.count)]), sequence: UInt64(offset)))
        }
        scores += try await session.finish()
        #expect(scores.reduce(0) { $0 + $1.sampleCount } == samples.count)
        #expect(scores.prefix(20).allSatisfy { $0.probability < 0.5 })
        #expect(scores.contains { $0.probability > 0.8 })
        if baseline.isEmpty { baseline = scores } else { #expect(scores == baseline) }
    }
    let session = try await provider.detectVoiceActivity(format: format)
    let first = try await session.process(pcm(Array(samples.prefix(4000)), sequence: 0))
    try await session.reset()
    #expect(try await session.process(pcm(Array(samples.prefix(4000)), sequence: 0)) == first)
    await session.cancel()
    let next = try await provider.detectVoiceActivity(format: format)
    #expect(try await next.finish().isEmpty)
    try await providerContext.unload()
    let segmentation = VoiceActivitySegmenter(session: try await provider.detectVoiceActivity(format: format))
    var utterances: [[AudioFrame]] = []
    var current: [AudioFrame] = []
    for offset in stride(from: 0, to: samples.count, by: 137) {
        let result = try await segmentation.process(
            pcm(
                Array(samples[offset..<min(offset + 137, samples.count)]), sequence: UInt64(offset)))
        for event in result.streamEvents {
            switch event {
            case .audio(let frames): current += frames
            case .end:
                if !current.isEmpty { utterances.append(current) }
                current.removeAll()
            }
        }
    }
    await segmentation.cancel()
    #expect(utterances.count == 1)
    #expect(utterances[0].reduce(0) { $0 + $1.duration } < 6)
    if #available(macOS 27, *), ProcessInfo.processInfo.environment["HARNESS_TEST_NEMOTRON"] == "1" {
        let asrContext = ModelContext()
        let asr = try NemotronASR(
            context: asrContext,
            artifacts: models.appendingPathComponent(
                "Nemotron-macos"))
        let recognition = try await asr.transcribe(SpeechRecognitionRequest(locale: "en-US", format: format))
        let reading = Task { () throws -> String in
            var text = ""
            for try await event in recognition.output.events { if event.isFinal { text = event.text } }
            return text
        }
        do {
            for frame in utterances[0] { try await recognition.send(frame) }
            try await recognition.finishInput()
            let text = try await reading.value
            #expect(text.lowercased().contains("quick brown fox"))
            print("Silero → Nemotron: \(text)")
        } catch {
            await recognition.cancel()
            reading.cancel()
            _ = try? await reading.value
            throw error
        }
        try await asrContext.unload()
    }
    try await providerContext.unload()
    print("Silero real model: silence/speech, packet parity, reset, tail, cancellation passed")
}

@Test func endpointTrimsTailButPreservesInternalPause() throws {
    var policy = BoundaryRecorder()
    var sequence: UInt64 = 0
    func frame() throws -> AudioFrame {
        defer { sequence += 1 }
        return try pcm(Array(repeating: 0, count: 512), sequence: sequence)
    }
    for _ in 0..<10 { _ = policy.consume(try frame(), probability: 0.9, threshold: 0.5) }
    for _ in 0..<10 { _ = policy.consume(try frame(), probability: 0.1, threshold: 0.5) }
    for _ in 0..<10 { _ = policy.consume(try frame(), probability: 0.9, threshold: 0.5) }
    var result: RecordedSegment?
    for _ in 0..<25 { result = policy.consume(try frame(), probability: 0.1, threshold: 0.5) }
    let segment = try #require(result)
    #expect(segment.reason == .silence)
    #expect(segment.frames.count == 36)
    #expect(segment.frames.map(\.sequence) == Array(0..<36).map(UInt64.init))
}

@Test func maximumDurationPreservesEverySampleAndDoesNotEndTurn() throws {
    var policy = BoundaryRecorder()
    var segments: [RecordedSegment] = []
    for index in 0..<800 {
        let frame = try pcm(Array(repeating: 0, count: 512), sequence: UInt64(index))
        if let segment = policy.consume(frame, probability: 0.9, threshold: 0.5) { segments.append(segment) }
    }
    #expect(policy.isSpeaking)
    #expect(segments.count == 2)
    #expect(segments.allSatisfy { $0.reason == .maximumDuration })
    let tail = policy.finish()
    segments.append(try #require(tail))
    #expect(segments.last?.reason == .inputFinished)
    #expect(segments.flatMap(\.frames).map(\.sequence) == Array(0..<800).map(UInt64.init))
    #expect(policy.finish() == nil)
}

@Test func silenceAfterExactChunkBoundaryDoesNotBecomeAnotherASRInput() throws {
    var policy = BoundaryRecorder()
    let frame = try pcm(Array(repeating: 0, count: 512), sequence: 0)
    for _ in 0..<375 { _ = policy.consume(frame, probability: 0.9, threshold: 0.5) }
    var last: RecordedSegment?
    for _ in 0..<25 { last = policy.consume(frame, probability: 0.1, threshold: 0.5) }
    #expect(last?.reason == .silence)
    #expect(last?.frames.isEmpty == true)
}

private actor ConstantVAD: VoiceActivitySession {
    var position: Int64 = 0
    var pending = 0
    var cancelled = false
    func process(_ frame: AudioFrame) throws -> [VoiceActivityScore] {
        pending += frame.sampleCount
        var scores: [VoiceActivityScore] = []
        while pending >= 512 {
            scores.append(try VoiceActivityScore(startSample: position, sampleCount: 512, probability: 0.9))
            pending -= 512
            position += 512
        }
        return scores
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() {
        position = 0
        pending = 0
    }
    func cancel() { cancelled = true }
}

@Test func finishPreservesSubframeTailAndCancelDiscardsIt() async throws {
    let vad = ConstantVAD()
    let segmenter = VoiceActivitySegmenter(session: vad)
    let initial = try await segmenter.process(pcm(Array(repeating: 0.2, count: 1700), sequence: 0))
    let tail = try await segmenter.finishStreaming()
    let events = initial.streamEvents + tail
    let sampleCount = events.reduce(0) { count, event in
        if case .audio(let frames) = event { return count + frames.reduce(0) { $0 + $1.sampleCount } }
        return count
    }
    #expect(sampleCount == 1700)
    guard case .end(.inputFinished) = tail.last else {
        Issue.record("Missing final boundary")
        return
    }
    #expect(await vad.cancelled)
    await #expect(throws: CapabilityError.self) { try await segmenter.finishStreaming() }
    let cancelled = VoiceActivitySegmenter(session: ConstantVAD())
    _ = try await cancelled.process(pcm(Array(repeating: 0.2, count: 1700), sequence: 0))
    await cancelled.cancel()
    await #expect(throws: CapabilityError.self) { try await cancelled.finishStreaming() }
}

@Test func continuousTurnLimitFailsRatherThanSilentlySubmittingTruncatedText() async throws {
    let segmenter = VoiceActivitySegmenter(session: ConstantVAD())
    var failed = false
    for index in 0..<62 {
        do {
            _ = try await segmenter.process(pcm(Array(repeating: 0.2, count: 16000), sequence: UInt64(index)))
        } catch CapabilityError.bufferOverflow {
            failed = true
            break
        }
    }
    #expect(failed)
    await segmenter.cancel()
}

@Test func liveCommittedFramesPreserveSamplesAcrossChunksAndPause() throws {
    var policy = SpeechBoundaryPolicy()
    var streamed: [UInt64] = []
    var endings: [VoiceSegmentEnd] = []
    for index in 0..<825 {
        let probability: Float = index >= 800 || (200..<210).contains(index) ? 0.1 : 0.9
        let frame = try pcm(Array(repeating: 0, count: 512), sequence: UInt64(index))
        _ = policy.consume(frame, probability: probability, threshold: 0.5)
        for event in policy.streamEvents {
            switch event {
            case .audio(let frames): streamed += frames.map(\.sequence)
            case .end(let reason): endings.append(reason)
            }
        }
    }
    #expect(streamed == Array(0..<806).map(UInt64.init))
    #expect(endings == [.maximumDuration, .maximumDuration, .silence])
}
