import AgentCore
import Foundation
import ModelKit
import OSLog

/// Acoustic vocabulary shared by production spotting and the Settings diagnostic.
struct SpeechKeywordLexicon: Decodable, Sendable {
    private struct Entry: Decodable, Sendable {
        let label: String
        let phrase: String
        let tokens: [String]
        let standalone: Bool

        var valid: Bool {
            (1...128).contains(label.utf8.count) && (1...128).contains(phrase.utf8.count)
                && (1...32).contains(tokens.count) && tokens.allSatisfy { (1...32).contains($0.utf8.count) }
        }
    }

    private let version: Int
    private let keywords: [Entry]
    private static let bundled = Result {
        try decode(AgentConfigurations.data("Agents/SpeechPerception/ZipformerKeywords.json"))
    }

    static func load() throws -> Self { try bundled.get() }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, (1...32).contains(value.keywords.count),
            Set(value.keywords.map(\.label)).count == value.keywords.count,
            value.keywords.allSatisfy(\.valid)
        else { throw AgentConfigurationError.invalidField("ZipformerKeywords.json") }
        return value
    }

    func keywords(threshold: Float = SpeechKeyword.defaultThreshold) -> [SpeechKeyword] {
        keywords.map { .init(label: $0.label, tokens: $0.tokens, standalone: $0.standalone, threshold: threshold) }
    }

    func phrase(for label: String) -> String? {
        keywords.first { $0.label == label }?.phrase
    }
}

/// One candidate feeds one bounded worker. Saturation retires the candidate instead of delaying ASR.
struct SpeechKeywordProbe {
    private static let log = Logger(subsystem: "dev.mobileharness", category: "SpeechKeyword")

    let id = UUID()
    let generation: String
    let onset: Duration
    var match: (label: String, at: Duration)?
    var delivered = false
    private struct Packet: Sendable {
        let samples: [Float]
        let capturedAt: Duration
    }
    private let input: AsyncStream<Packet>.Continuation
    private let worker: Task<Void, Never>

    init(
        capability: any KeywordSpottingCapability, generation: String, onset: Duration, keywords: [SpeechKeyword],
        onMatch: @escaping @Sendable (UUID, String, Duration) async -> Void
    ) {
        self.generation = generation
        self.onset = onset
        let stream = AsyncStream.makeStream(of: Packet.self, bufferingPolicy: .bufferingOldest(8))
        input = stream.continuation
        let id = id
        worker = Task(priority: .userInitiated) {
            defer { stream.continuation.finish() }
            do {
                guard let session = try await capability.openKeywords(keywords) else {
                    return
                }
                do {
                    var tail: [Float] = []
                    for await packet in stream.stream {
                        let samples = packet.samples
                        try Task.checkCancellation()
                        tail = Array((tail + samples).suffix(2560))
                        if let label = try await session.accept(samples) {
                            if Self.hasSilentTail(tail), !Task.isCancelled {
                                await onMatch(id, label, packet.capturedAt + .nanoseconds(samples.count * 62_500))
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

    func submit(_ samples: [Float], capturedAt: Duration) -> Bool {
        switch input.yield(Packet(samples: samples, capturedAt: capturedAt)) {
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
    private let lexicon: SpeechKeywordLexicon
    private var tail: [Float] = []
    private var finished = false
    private var heardAudio = false
    private var quietSamples = 0
    private var receivedSamples = 0
    private var lastReportedSamples = 0
    private var peakRMS: Float = 0

    init(
        session: any KeywordSpottingSession, lexicon: SpeechKeywordLexicon,
        reopen: @escaping @Sendable () async throws -> any KeywordSpottingSession
    ) {
        self.session = session
        self.lexicon = lexicon
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
        observation.hit = (lexicon.phrase(for: label) ?? label, silentTail)
        return observation
    }

    func stop() async {
        guard !finished else { return }
        finished = true
        tail.removeAll()
        await session.cancel()
    }
}
