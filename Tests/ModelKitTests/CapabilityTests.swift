import Foundation
import ModelKit
import Testing

private actor AudioRecorder {
    var sequences: [UInt64] = []
    var finishes = 0
    func record(_ frame: AudioFrame) { sequences.append(frame.sequence) }
    func finish() { finishes += 1 }
}

@Test func recognitionInputEndsBeforeFinalOutput() async throws {
    let format = try AudioFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16)
    let pair = InferenceSession<TranscriptionEvent>.make(
        limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
    let recorder = AudioRecorder()
    let segment = UUID()
    let session = SpeechRecognitionSession(
        output: pair.session, format: format,
        sendAudio: { await recorder.record($0) },
        finishInput: {
            await recorder.finish()
            try pair.emitter.yield(TranscriptionEvent(segmentID: segment, revision: 0, text: "完成", isFinal: true))
            pair.emitter.finish()
        })
    try await session.send(AudioFrame(data: Data([0, 0]), format: format, sequence: 0, timestamp: 0))
    try await session.finishInput()
    var iterator = session.output.events.makeAsyncIterator()
    #expect(try await iterator.next()?.text == "完成")
    #expect(try await iterator.next() == nil)
    #expect(await recorder.sequences == [0])
    #expect(await recorder.finishes == 1)
    await #expect(throws: CapabilityError.sessionClosed) {
        try await session.send(AudioFrame(data: Data([0, 0]), format: format, sequence: 1, timestamp: 1))
    }
}

@Test func recognitionRejectsAudioAfterCancellation() async throws {
    let format = try AudioFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16)
    let pair = InferenceSession<TranscriptionEvent>.make(
        limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
    let recorder = AudioRecorder()
    let session = SpeechRecognitionSession(
        output: pair.session, format: format,
        sendAudio: { await recorder.record($0) }, finishInput: {})
    await session.cancel()
    await #expect(throws: CapabilityError.sessionClosed) {
        try await session.send(AudioFrame(data: Data([0, 0]), format: format, sequence: 0, timestamp: 0))
    }
    #expect(await recorder.sequences.isEmpty)
}

@Test func recognitionOrderingFailureTerminatesOutput() async throws {
    let format = try AudioFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16)
    let pair = InferenceSession<TranscriptionEvent>.make(
        limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
    let session = SpeechRecognitionSession(output: pair.session, format: format, sendAudio: { _ in }, finishInput: {})
    let frame = try AudioFrame(data: Data([0, 0]), format: format, sequence: 1, timestamp: 0)
    try await session.send(frame)
    await #expect(throws: CapabilityError.self) { try await session.send(frame) }
    var iterator = session.output.events.makeAsyncIterator()
    await #expect(throws: CapabilityError.self) { _ = try await iterator.next() }
}

@Test func requestValidationRejectsInvalidInput() throws {
    #expect(throws: CapabilityError.self) { _ = try ChatRequest(messages: []) }
    #expect(throws: CapabilityError.self) {
        _ = try ChatRequest(messages: [ChatMessage(role: .user, content: "hi")], temperature: .nan)
    }
    #expect(throws: CapabilityError.self) { _ = try StreamLimits(capacity: 0) }
    #expect(throws: CapabilityError.self) { _ = try StreamLimits(capacity: Int.max, maximumEventBytes: 2) }
    let format = try AudioFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16)
    #expect(throws: CapabilityError.self) {
        _ = try AudioFrame(data: Data([0]), format: format, sequence: 0, timestamp: 0)
    }
    #expect(throws: CapabilityError.self) { _ = try SpeechSynthesisRequest(text: " ", locale: "zh-CN") }
    let request = try JudgeRequest(text: "hello", candidates: ["chat", "camera"])
    #expect(throws: CapabilityError.self) {
        _ = try JudgeResult(decision: .selected(label: "move", score: 1), for: request)
    }
    #expect(throws: CapabilityError.self) {
        _ = try JudgeResult(decision: .selected(label: "chat", score: .nan), for: request)
    }
    #expect(try JudgeResult(decision: .abstained, for: request).decision == .abstained)
}

private actor InputGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}

@Test func concurrentRecognitionInputIsRejectedWithoutLosingAcceptedFrame() async throws {
    let format = try AudioFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16)
    let output = InferenceSession<TranscriptionEvent>.make(
        limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let gate = InputGate()
    let session = SpeechRecognitionSession(
        output: output.session, format: format,
        sendAudio: { _ in
            entered.continuation.yield(())
            await gate.wait()
        }, finishInput: { output.emitter.finish() })
    let frame = try AudioFrame(data: Data([0, 0]), format: format, sequence: 0, timestamp: 0)
    let first = Task { try await session.send(frame) }
    var readiness = entered.stream.makeAsyncIterator()
    _ = await readiness.next()
    await #expect(throws: CapabilityError.inputBusy) { try await session.send(frame) }
    await #expect(throws: CapabilityError.inputBusy) { try await session.finishInput() }
    await gate.release()
    try await first.value
    try await session.finishInput()
    var events = session.output.events.makeAsyncIterator()
    #expect(try await events.next() == nil)
    entered.continuation.finish()
}
