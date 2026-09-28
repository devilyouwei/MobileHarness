import Foundation

/// Preserves source text while waiting for one following character to disambiguate a boundary.
/// Soft length boundaries preserve words; the pending buffer retains a hard 2,000-byte safety bound.
struct SentenceFunctionBuffer {
    private var buffer = ""
    private static let punctuation = Set<Character>(",，、;；:：.!?。！？؛،؟।॥\n\r")
    private static let sentenceEnds = Set<Character>(";；.!?。！？؛؟।॥\n\r")
    private static let closing = Set<Character>("\"'”’»›）)]}」』】》〉")
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc"]

    mutating func append(_ delta: String) throws -> [String] {
        guard buffer.utf8.count + delta.utf8.count <= 2000 else { throw GenerationError.limitExceeded }
        buffer += delta
        return extract(finishing: false)
    }

    mutating func finish() -> [String] { extract(finishing: true) }

    private mutating func extract(finishing: Bool) -> [String] {
        let characters = Array(buffer)
        var output: [String] = []
        var start = 0
        var index = 0
        var containsHanzi = false
        while index < characters.count {
            let prefix = characters[start...index]
            containsHanzi = containsHanzi || Self.isCJK(characters[index])
            let threshold = containsHanzi ? 60 : 120
            let lengthBoundary =
                index - start + 1 >= threshold && index + 1 < characters.count
                && Self.canSplit(after: characters[index], before: characters[index + 1])
            guard Self.sentenceEnds.contains(characters[index]) || characters[index] == "\r\n" || lengthBoundary,
                Self.hasContent(prefix)
            else {
                index += 1
                continue
            }
            if characters[index] == ".", Self.isEmbeddedDot(characters, at: index) {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count,
                Self.isBoundary(characters[end]) || Self.closing.contains(characters[end])
                    || characters[end].isWhitespace
            {
                end += 1
            }
            // A later delta may contain a closing quote, another mark, or whitespace belonging to this sentence.
            guard end < characters.count else { break }
            output.append(String(characters[start..<end]))
            start = end
            index = end
            containsHanzi = false
        }
        buffer = String(characters[start...])
        if finishing, !buffer.isEmpty {
            if Self.hasContent(buffer) {
                output.append(buffer)
            } else if !output.isEmpty {
                // Keep punctuation/whitespace attached to speech, never create an empty utterance.
                output[output.count - 1] += buffer
            }
            buffer = ""
        }
        return output
    }

    private static func isBoundary(_ character: Character) -> Bool {
        punctuation.contains(character) || character == "\r\n"
    }

    private static func hasContent<S: Sequence>(_ characters: S) -> Bool where S.Element == Character {
        characters.contains { !$0.isWhitespace && !isBoundary($0) && !closing.contains($0) }
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0x20000...0x2FA1F).contains($0.value)
        }
    }

    private static func canSplit(after previous: Character, before next: Character) -> Bool {
        func word(_ value: Character) -> Bool {
            (value.isLetter || value.isNumber || "'’_-.,".contains(value)) && !isCJK(value)
        }
        return !(word(previous) && word(next))
    }

    private static func isEmbeddedDot(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0, index + 1 < characters.count else { return false }
        let previous = characters[index - 1]
        let next = characters[index + 1]
        if previous.isNumber && next.isNumber { return true }
        var start = index
        while start > 0, characters[start - 1].isLetter || characters[start - 1] == "." { start -= 1 }
        let token = String(characters[start..<index])
        if token.count == 1, previous.isUppercase, next.isUppercase { return true }
        let word = token.lowercased()
        if abbreviations.contains(word) { return true }
        let initials = word.split(separator: ".", omittingEmptySubsequences: false)
        return initials.count > 1 && initials.allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
    }
}
