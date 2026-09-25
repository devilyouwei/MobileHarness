import Foundation
import ModelKit

/// The selected export ships only US English dictionary preprocessing.
enum KokoroInput {
    static func validate(text: String, locale: String) throws {
        guard ["en", "en-US"].contains(locale) else {
            throw CapabilityError.invalidRequest("此 Kokoro 制品目前只支持 en-US 英语前处理")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2048 else {
            throw CapabilityError.invalidRequest("Kokoro text must contain 1...2048 UTF-8 bytes")
        }
        let punctuation = CharacterSet(charactersIn: ".,!?;:'’\"“”()-")
        guard
            text.unicodeScalars.allSatisfy({ scalar in
                (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                    || punctuation.contains(scalar)
            }), text.contains(where: { $0.isLetter || $0.isNumber })
        else {
            throw CapabilityError.invalidRequest("Kokoro English validation rejects unsupported characters")
        }
        // This dictionary frontend has no reliable decimal/currency normalization.
        guard text.range(of: #"[0-9][.,][0-9]"#, options: .regularExpression) == nil else {
            throw CapabilityError.invalidRequest("Spell out decimal numbers before Kokoro synthesis")
        }
    }

    /// Split at word boundaries before the fixed token bucket; never truncate text.
    static func chunks(_ text: String, tokenCount: (String) -> Int) throws -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard tokenCount(word) <= 128 else {
                throw CapabilityError.invalidRequest("Kokoro word exceeds token bucket")
            }
            let candidate = current.isEmpty ? word : current + " " + word
            if tokenCount(candidate) > 128 {
                chunks.append(current)
                current = word
            } else {
                current = candidate
            }
            if let last = word.last, ".!?;".contains(last) {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        guard !chunks.isEmpty, chunks.count <= 32 else {
            throw CapabilityError.invalidRequest("Too many Kokoro chunks")
        }
        return chunks
    }

    static func alignment(duration: [Float]) throws -> ([Float], [Float], Int) {
        guard (2...128).contains(duration.count), duration.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 512 }) else {
            throw CapabilityError.invalidRequest("Invalid Kokoro durations")
        }
        // PyTorch round uses ties-to-even.
        let lengths = duration.map { max(1, Int($0.rounded(.toNearestOrEven))) }
        let total = lengths.reduce(0, +)
        guard total <= 512 else {
            throw CapabilityError.invalidRequest("Kokoro frame bucket exceeded; use shorter text")
        }
        var alignment = [Float](repeating: 0, count: 128 * 512)
        var frame = 0
        for (token, length) in lengths.enumerated() {
            for _ in 0..<length {
                alignment[token * 512 + frame] = 1
                frame += 1
            }
        }
        return (alignment, [Float](repeating: 1, count: total) + [Float](repeating: 0, count: 512 - total), total)
    }
}
