import Foundation
import ModelKit

/// Four-path transducer beam search. Phrase bias and the preceding token context persist across encoder calls.
struct ZipformerKeywordDecoder {
    private struct Hypothesis {
        var tokens = [-1, 0]
        var prefix: [Int] = []
        var probabilities: [Float] = []
        var blanks = 0
        var score: Double = 0
        var emittedTokens = 0
    }

    private let keywords: [[Int]: SpeechKeyword]
    private let prefixScores: [[Int]: Double]
    private let history: Int
    private var beam = [Hypothesis()]
    private var decoderCache: [[Int]: [Float]] = [:]

    init(keywords: [[Int]: SpeechKeyword]) {
        self.keywords = keywords
        var scores: [[Int]: Double] = [[]: 0]
        for phrase in keywords.keys {
            for count in 1...phrase.count { scores[Array(phrase.prefix(count))] = Double(count) }
        }
        prefixScores = scores
        history = (keywords.keys.map(\.count).max() ?? 0) + 2
    }

    mutating func accept(
        _ frame: [Float],
        decode: ([Int]) async throws -> [Float],
        join: ([Float], [Float]) async throws -> [Float]
    ) async throws -> String? {
        var candidates: [(row: Int, token: Int, score: Double, probability: Float)] = []
        for (index, hypothesis) in beam.enumerated() {
            let context = Array(hypothesis.tokens.suffix(2))
            let vector: [Float]
            if let existing = decoderCache[context] {
                vector = existing
            } else {
                vector = try await decode(context)
                if decoderCache.count == 128 { decoderCache.removeAll(keepingCapacity: true) }
                decoderCache[context] = vector
            }
            let logits = try await join(frame, vector)
            guard logits.count == 263, let maximum = logits.max() else {
                throw CapabilityError.invalidRequest("Unexpected Zipformer logits")
            }
            let exponentials = logits.map { exp($0 - maximum) }
            let normalization = exponentials.reduce(0, +)
            for token in logits.indices {
                let probability = exponentials[token] / normalization
                candidates.append(
                    (index, token, hypothesis.score + Double(logits[token] - maximum - log(normalization)), probability)
                )
            }
        }
        var next: [Hypothesis] = []
        for entry in candidates.sorted(by: { $0.score > $1.score }).prefix(4) {
            var candidate = beam[entry.row]
            candidate.score = entry.score
            if entry.token == 0 || entry.token == 2 {
                candidate.blanks += 1
            } else {
                candidate.emittedTokens = min(history, candidate.emittedTokens + 1)
                let previous = prefixScores[candidate.prefix, default: 0]
                candidate.prefix.append(entry.token)
                while prefixScores[candidate.prefix] == nil { candidate.prefix.removeFirst() }
                let matches = matchingSuffixes(candidate.prefix)
                candidate.score += prefixScores[candidate.prefix, default: 0] - previous
                candidate.score += matches.reduce(0) { $0 + prefixScores[$1, default: 0] }
                if candidate.prefix.isEmpty {
                    candidate = Hypothesis(score: candidate.score, emittedTokens: candidate.emittedTokens)
                } else {
                    candidate.tokens = Array((candidate.tokens + [entry.token]).suffix(history))
                    candidate.probabilities = Array((candidate.probabilities + [entry.probability]).suffix(history))
                    candidate.blanks = 0
                }
            }
            if let index = next.firstIndex(where: {
                $0.tokens == candidate.tokens && $0.emittedTokens == candidate.emittedTokens
            }) {
                let best = max(next[index].score, candidate.score)
                next[index].score = best + log1p(exp(min(next[index].score, candidate.score) - best))
            } else {
                next.append(candidate)
            }
        }
        beam = next
        guard let best = next.max(by: { $0.score < $1.score }), best.blanks > 0 else { return nil }
        for match in matchingSuffixes(best.prefix) {
            guard let keyword = keywords[match],
                !keyword.standalone || (best.emittedTokens == match.count && best.blanks >= 2)
            else { continue }
            let mean = best.probabilities.suffix(match.count).reduce(0, +) / Float(match.count)
            if mean >= keyword.threshold { return keyword.label }
        }
        return nil
    }

    private func matchingSuffixes(_ prefix: [Int]) -> [[Int]] {
        prefix.indices.compactMap { index in
            let suffix = Array(prefix[index...])
            return keywords[suffix] == nil ? nil : suffix
        }
    }
}
