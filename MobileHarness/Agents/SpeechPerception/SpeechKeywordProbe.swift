import Foundation
import ModelKit
import OSLog

/// One candidate feeds one bounded worker. Saturation retires the candidate instead of delaying ASR.
struct SpeechKeywordProbe {
    private static let log = Logger(subsystem: "dev.mobileharness", category: "SpeechKeyword")
    private static let lexicon: [(keyword: SpeechKeyword, phrase: String)] = [
        (.init(label: "zh-stop-talking", tokens: ["x", "iān", "b", "ié", "sh", "uō", "l", "e"]), "先别说了"),
        (.init(label: "zh-stop-playback", tokens: ["t", "íng", "zh", "ǐ", "b", "ō", "b", "ào"]), "停止播报"),
        (
            .init(label: "en-stop-talking", tokens: ["S", "T", "AA1", "P", "T", "AO1", "K", "IH0", "NG"]),
            "stop talking"
        ),
        (.init(label: "en-please-stop", tokens: ["P", "L", "IY1", "Z", "S", "T", "AA1", "P"]), "please stop"),
        (.init(label: "en-stop", tokens: ["S", "T", "AA1", "P"], standalone: true), "stop"),
        (.init(label: "zh-stop", tokens: ["t", "íng", "x", "ià"], standalone: true), "停下"),
    ]
    static let keywords = lexicon.map(\.keyword)

    static func keywords(threshold: Float) -> [SpeechKeyword] {
        keywords.map { .init(label: $0.label, tokens: $0.tokens, standalone: $0.standalone, threshold: threshold) }
    }

    static func phrase(for label: String) -> String {
        lexicon.first { $0.keyword.label == label }?.phrase ?? label
    }

    let id = UUID()
    let replyID: UUID
    let captureID: UUID
    var matched = false
    var delivered = false
    private let input: AsyncStream<[Float]>.Continuation
    private let worker: Task<Void, Never>

    init(
        capability: any KeywordSpottingCapability, replyID: UUID, captureID: UUID,
        threshold: Float = SpeechKeyword.defaultThreshold,
        onMatch: @escaping @Sendable (UUID) async -> Void
    ) {
        self.replyID = replyID
        self.captureID = captureID
        let stream = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingOldest(8))
        input = stream.continuation
        let id = id
        worker = Task(priority: .userInitiated) {
            defer { stream.continuation.finish() }
            do {
                guard let session = try await capability.openKeywords(Self.keywords(threshold: threshold)) else {
                    return
                }
                do {
                    var tail: [Float] = []
                    for await samples in stream.stream {
                        try Task.checkCancellation()
                        tail = Array((tail + samples).suffix(2560))
                        if try await session.accept(samples) != nil {
                            if Self.hasSilentTail(tail), !Task.isCancelled {
                                await onMatch(id)
                            } else if !Task.isCancelled {
                                Self.log.debug("Keyword hit rejected by the silent tail gate")
                            }
                            break
                        }
                    }
                } catch {
                    await session.cancel()
                    throw error
                }
                await session.cancel()
            } catch is CancellationError {
            } catch {
                Self.log.error("Keyword probe unavailable: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func submit(_ samples: [Float]) -> Bool {
        switch input.yield(samples) {
        case .enqueued, .terminated: return true
        case .dropped:
            Self.log.notice("Keyword probe queue full; deferring to the ASR transcript")
            return false
        @unknown default: return false
        }
    }

    func finished() async { await worker.value }

    func cancel() {
        worker.cancel()
        input.finish()
    }

    static func hasSilentTail(_ tail: [Float]) -> Bool {
        guard tail.count == 2560 else { return false }
        return stride(from: 0, to: tail.count, by: 160).allSatisfy { start in
            let energy = tail[start..<(start + 160)].reduce(Float(0)) { $0 + $1 * $1 }
            return energy < 160 * 0.006 * 0.006
        }
    }
}

/// A single diagnostic attempt reports the first raw hit, including a rejected tail.
actor SpeechKeywordTest {
    struct Observation: Sendable {
        var audio: (samples: Int, rms: Float)?
        var hit: (phrase: String, silentTail: Bool)?
    }

    private var session: any KeywordSpottingSession
    private let reopen: @Sendable () async throws -> any KeywordSpottingSession
    private var tail: [Float] = []
    private var finished = false
    private var heardAudio = false
    private var quietSamples = 0
    private var receivedSamples = 0
    private var lastReportedSamples = 0
    private var peakRMS: Float = 0

    init(
        session: any KeywordSpottingSession,
        reopen: @escaping @Sendable () async throws -> any KeywordSpottingSession
    ) {
        self.session = session
        self.reopen = reopen
    }

    func accept(_ samples: [Float]) async throws -> Observation {
        guard !finished, !samples.isEmpty else { return Observation() }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        var packet = samples
        if rms >= 0.006 {
            if heardAudio, quietSamples >= 9600 {
                await session.cancel()
                try Task.checkCancellation()
                guard !finished else { return Observation() }
                let fresh = try await reopen()
                if finished || Task.isCancelled {
                    await fresh.cancel()
                    throw CancellationError()
                }
                session = fresh
                tail = Array(tail.suffix(1600))
                packet = tail + samples
            }
            heardAudio = true
            quietSamples = 0
        } else {
            quietSamples = min(9600, quietSamples + samples.count)
        }
        tail = Array((tail + samples).suffix(2560))
        let label = try await session.accept(packet)
        try Task.checkCancellation()
        guard !finished else { return Observation() }
        receivedSamples += samples.count
        peakRMS = max(peakRMS, rms)
        var observation = Observation()
        if receivedSamples - lastReportedSamples >= 1600 || label != nil {
            observation.audio = (receivedSamples, peakRMS)
            lastReportedSamples = receivedSamples
            peakRMS = 0
        }
        guard let label else { return observation }
        let silentTail = SpeechKeywordProbe.hasSilentTail(tail)
        await stop()
        observation.hit = (SpeechKeywordProbe.phrase(for: label), silentTail)
        return observation
    }

    func stop() async {
        guard !finished else { return }
        finished = true
        tail.removeAll()
        await session.cancel()
    }
}
