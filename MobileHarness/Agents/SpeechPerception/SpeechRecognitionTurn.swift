import Foundation
import ModelKit
import Storage

/// Live, VAD-committed PCM -> capability events. Preview never submits an Agent input.
actor SpeechRecognitionTurn {
    private let recognition: any SpeechRecognitionCapability
    private let sessionID: String
    private let preview: @Sendable (String) async throws -> Void
    private var queue: [VoiceStreamEvent] = []
    private var queuedSamples = 0
    private var worker: Task<Void, Error>?
    private var reader: Task<String, Error>?
    private var session: SpeechRecognitionSession?
    private var completed = ""
    private var failure: (any Error)?
    private var sealed = false
    private var cancelled = false

    init(
        recognition: any SpeechRecognitionCapability, sessionID: String,
        preview: @escaping @Sendable (String) async throws -> Void
    ) {
        self.recognition = recognition
        self.sessionID = sessionID
        self.preview = preview
    }

    /// At most 128 work items / four seconds of queued PCM; no total utterance time limit.
    func enqueue(_ events: [VoiceStreamEvent]) throws {
        guard !sealed, !cancelled else { throw CapabilityError.sessionClosed }
        if let failure { throw failure }
        var count = 0
        for event in events {
            if case .audio(let frames) = event {
                guard frames.count <= 64,
                    frames.allSatisfy({
                        $0.sampleCount <= 16000 && $0.format.sampleRate == 16000
                            && $0.format.channels == 1 && $0.format.encoding == .float32
                    })
                else { throw CapabilityError.invalidRequest("Invalid live PCM") }
                count += frames.reduce(0) { $0 + $1.sampleCount }
            }
        }
        guard queue.count + events.count <= 128, queuedSamples + count <= 64000
        else { throw CapabilityError.bufferOverflow }
        queuedSamples += count
        queue += events
        if worker == nil { worker = Task { try await self.drain() } }
    }

    private func open() async throws {
        guard session == nil else { return }
        let stream = try await recognition.transcribe(
            SpeechRecognitionRequest(
                locale: "auto", format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32),
                context: InferenceContext(scopeID: sessionID)))
        if cancelled || Task.isCancelled {
            await stream.cancel()
            throw CancellationError()
        }
        session = stream
        let prefix = completed
        let preview = preview
        reader = Task {
            var transcript = TranscriptAccumulator(prefix: prefix)
            for try await event in stream.output.events {
                try Task.checkCancellation()
                if let visible = try transcript.accept(event) { try await preview(visible) }
            }
            return transcript.finalText
        }
    }

    private func endSegment() async throws {
        guard let session else { return }
        try await session.finishInput()
        let text = try await reader?.value ?? ""
        try Task.checkCancellation()
        completed = Self.join(completed, text)
        guard completed.utf8.count <= 65536 else { throw CapabilityError.eventTooLarge }
        await session.cancel()
        self.session = nil
        reader = nil
    }

    private func drain() async throws {
        do {
            while !queue.isEmpty {
                try Task.checkCancellation()
                let event = queue.removeFirst()
                switch event {
                case .audio(let frames):
                    queuedSamples -= frames.reduce(0) { $0 + $1.sampleCount }
                    if !frames.isEmpty {
                        try await open()
                        for frame in frames { try await session?.send(frame) }
                    }
                case .end: try await endSegment()
                }
            }
            worker = nil
        } catch {
            failure = error
            queue.removeAll()
            queuedSamples = 0
            reader?.cancel()
            await session?.cancel()
            throw error
        }
    }

    func finish() async throws -> String {
        guard !sealed, !cancelled else { throw CapabilityError.sessionClosed }
        sealed = true
        return try await withTaskCancellationHandler {
            try await finishAccepted()
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    private func finishAccepted() async throws -> String {
        if let worker { try await worker.value }
        try Task.checkCancellation()
        if let failure { throw failure }
        guard !cancelled else { throw CancellationError() }
        try await endSegment()
        return completed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func cancel() async {
        cancelled = true
        sealed = true
        queue.removeAll()
        queuedSamples = 0
        worker?.cancel()
        reader?.cancel()
        await session?.cancel()
        if let worker { _ = await worker.result }
        if let reader { _ = await reader.result }
        worker = nil
        reader = nil
        session = nil
        completed = ""
    }
    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}

// MARK: - Transcript accumulation

/// Pure revision/order policy for one ASR segment; no runtime or presentation effects.
struct TranscriptAccumulator {
    let prefix: String
    private var segments: [String: TranscriptionEvent] = [:]
    private var order: [String] = []

    init(prefix: String = "") { self.prefix = prefix }

    mutating func accept(_ event: TranscriptionEvent) throws -> String? {
        guard event.text.utf8.count <= 16384 else { throw CapabilityError.eventTooLarge }
        if let old = segments[event.segmentID], old.isFinal || old.revision >= event.revision { return nil }
        var candidateOrder = order
        if segments[event.segmentID] == nil {
            guard order.count < 64 else { throw CapabilityError.eventTooLarge }
            candidateOrder.append(event.segmentID)
        }
        var candidate = segments
        candidate[event.segmentID] = event
        let current = candidateOrder.compactMap { candidate[$0]?.text }.joined(separator: " ")
        let visible = prefix.isEmpty ? current : current.isEmpty ? prefix : prefix + " " + current
        guard visible.utf8.count <= 65536 else { throw CapabilityError.eventTooLarge }
        order = candidateOrder
        segments = candidate
        return visible
    }

    var finalText: String {
        order.compactMap { segments[$0].flatMap { $0.isFinal ? $0.text : nil } }.joined(separator: " ")
    }
}
