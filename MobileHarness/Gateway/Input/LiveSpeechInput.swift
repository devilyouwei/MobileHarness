import Foundation
import ModelKit

/// Live, VAD-committed PCM -> capability events. Preview never submits an Agent input.
public actor LiveSpeechInput {
    private let requests: InputGateway
    private let sessionID: UUID
    private let preview: @Sendable (String) async -> Void
    private var queue: [VoiceStreamEvent] = []
    private var queuedSamples = 0
    private var totalSamples = 0
    private var worker: Task<Void, Error>?
    private var reader: Task<String, Error>?
    private var session: SpeechRecognitionSession?
    private var completed = ""
    private var failure: (any Error)?
    private var sealed = false
    private var cancelled = false

    public init(requests: InputGateway, sessionID: UUID, preview: @escaping @Sendable (String) async -> Void) {
        self.requests = requests
        self.sessionID = sessionID
        self.preview = preview
    }

    /// At most 128 work items / four seconds of queued PCM, one minute per turn.
    public func enqueue(_ events: [VoiceStreamEvent]) throws {
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
        guard queue.count + events.count <= 128, queuedSamples + count <= 64000,
            totalSamples + count <= 960000
        else { throw CapabilityError.bufferOverflow }
        totalSamples += count
        queuedSamples += count
        queue += events
        if worker == nil { worker = Task { try await self.drain() } }
    }

    private func open() async throws {
        guard session == nil else { return }
        let stream = try await requests.openSpeechStream(sessionID: sessionID)
        if cancelled || Task.isCancelled {
            await stream.cancel()
            throw CancellationError()
        }
        session = stream
        let prefix = completed
        let preview = preview
        reader = Task {
            var segments: [UUID: TranscriptionEvent] = [:]
            var order: [UUID] = []
            for try await event in stream.output.events {
                try Task.checkCancellation()
                guard event.text.utf8.count <= 16384 else { throw CapabilityError.eventTooLarge }
                if let old = segments[event.segmentID], old.isFinal || old.revision >= event.revision { continue }
                if segments[event.segmentID] == nil {
                    guard order.count < 64 else { throw CapabilityError.eventTooLarge }
                    order.append(event.segmentID)
                }
                segments[event.segmentID] = event
                let current = order.compactMap { segments[$0]?.text }.joined(separator: " ")
                let visible = Self.join(prefix, current)
                guard visible.utf8.count <= 65536 else { throw CapabilityError.eventTooLarge }
                await preview(visible)
            }
            return order.compactMap { segments[$0].flatMap { $0.isFinal ? $0.text : nil } }.joined(separator: " ")
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

    public func finish() async throws -> String {
        guard !sealed, !cancelled else { throw CapabilityError.sessionClosed }
        sealed = true
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.finishAccepted() }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    await self.cancel()
                    throw CapabilityError.unavailable("语音识别超时")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
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
    public func cancel() async {
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
