import Foundation

public struct SpeechRecognitionRequest: Sendable {
    public let context: InferenceContext
    public let locale: String
    public let format: AudioFormat
    public init(locale: String, format: AudioFormat, context: InferenceContext = InferenceContext()) throws {
        guard !locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CapabilityError.invalidRequest("Missing recognition locale") }
        self.locale = locale
        self.format = format
        self.context = context
    }
}

public struct TranscriptionEvent: Equatable, Sendable {
    public let segmentID: String
    public let revision: UInt64
    public let text: String
    public let isFinal: Bool
    public init(segmentID: String, revision: UInt64, text: String, isFinal: Bool) {
        self.segmentID = segmentID
        self.revision = revision
        self.text = text
        self.isFinal = isFinal
    }
    public var estimatedBytes: Int { text.utf8.count + 64 }
}

public protocol SpeechRecognitionCapability: Capability {
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession
}

public final class SpeechRecognitionSession: Sendable {
    public let output: InferenceSession<TranscriptionEvent>
    private let input: RecognitionInput

    /// sendAudio must await acceptance, not queue audio without a bound. finishInput flushes final results.
    public init(
        output: InferenceSession<TranscriptionEvent>, format: AudioFormat,
        sendAudio: @escaping @Sendable (AudioFrame) async throws -> Void,
        finishInput: @escaping @Sendable () async throws -> Void
    ) {
        self.output = output
        input = RecognitionInput(format: format, sendAudio: sendAudio, finishInput: finishInput)
    }
    public func send(_ frame: AudioFrame) async throws {
        do {
            try output.requireOpen()
            try await input.send(frame)
        } catch {
            // Concurrent input is rejected without terminating the accepted send.
            if (error as? CapabilityError) != .inputBusy { output.fail(error) }
            throw error
        }
    }
    public func finishInput() async throws {
        do {
            try output.requireOpen()
            try await input.finish()
        } catch {
            if (error as? CapabilityError) != .inputBusy { output.fail(error) }
            throw error
        }
    }
    public func cancel() async {
        output.cancel()
        await input.cancel()
    }
}

private actor RecognitionInput {
    let format: AudioFormat
    let sendAudio: @Sendable (AudioFrame) async throws -> Void
    let finishInput: @Sendable () async throws -> Void
    var closed = false
    var busy = false
    var lastSequence: UInt64?
    var lastTimestamp: TimeInterval?

    init(
        format: AudioFormat, sendAudio: @escaping @Sendable (AudioFrame) async throws -> Void,
        finishInput: @escaping @Sendable () async throws -> Void
    ) {
        self.format = format
        self.sendAudio = sendAudio
        self.finishInput = finishInput
    }
    func send(_ frame: AudioFrame) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CapabilityError.inputFinished }
        guard !busy else { throw CapabilityError.inputBusy }
        guard frame.format == format, lastSequence.map({ frame.sequence > $0 }) ?? true,
            lastTimestamp.map({ frame.timestamp >= $0 }) ?? true
        else { throw CapabilityError.invalidRequest("Audio format or frame order mismatch") }
        busy = true
        defer { busy = false }
        do {
            try await sendAudio(frame)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            lastSequence = frame.sequence
            lastTimestamp = frame.timestamp
        } catch {
            closed = true
            throw error
        }
    }
    func finish() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CapabilityError.inputFinished }
        guard !busy else { throw CapabilityError.inputBusy }
        closed = true
        try await finishInput()
    }
    func cancel() { closed = true }
}
