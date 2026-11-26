import FluidAudio
import Foundation
import ModelKit

public enum KokoroVoiceCatalog {
    public static let modelID = "kokoro-82m"
    public static let defaultEnglish = "af_heart"
    public static let defaultMandarin = "zf_001"
    public static let voicesByLanguage: [String: [String]] = [
        "en": [defaultEnglish]
            + KokoroAneVariant.english.knownVoices.filter {
                ($0.hasPrefix("a") || $0.hasPrefix("b")) && $0 != defaultEnglish
            },
        "zh": [defaultMandarin] + KokoroAneVariant.mandarin.knownVoices.filter { $0 != defaultMandarin },
    ]

    public static func contains(_ voice: String) -> Bool {
        voicesByLanguage.values.contains { $0.contains(voice) }
    }

    static func language(of voice: String) -> KokoroInput.Language? {
        if voicesByLanguage["en"]?.contains(voice) == true { return .english }
        if voicesByLanguage["zh"]?.contains(voice) == true { return .mandarin }
        return nil
    }

    static func voice(for language: KokoroInput.Language, preferred: String?) -> String {
        if let preferred, Self.language(of: preferred) == language { return preferred }
        return language == .english ? defaultEnglish : defaultMandarin
    }
}

/// The provisioned frontends are English and Mandarin. `auto` splits mixed scripts in order.
enum KokoroInput {
    enum Language: Sendable, Equatable { case english, mandarin }
    struct Segment: Sendable, Equatable {
        let text: String
        let language: Language
    }

    static func segments(text: String, locale: String, preferredLanguage: Language? = nil) throws -> [Segment] {
        let locale = locale.lowercased().replacingOccurrences(of: "_", with: "-")
        guard ["auto", "en", "en-us", "en-gb", "zh", "zh-cn", "zh-hans", "zh-tw", "zh-hant"].contains(locale) else {
            throw CapabilityError.invalidRequest("Kokoro currently supports Mandarin and English only")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2048 else {
            throw CapabilityError.invalidRequest("Kokoro text must contain 1...2048 UTF-8 bytes")
        }
        let hasHanzi = text.unicodeScalars.contains(where: isHanzi)
        if locale.hasPrefix("en"), hasHanzi {
            throw CapabilityError.invalidRequest("English locale cannot synthesize Hanzi; use auto or zh-CN")
        }
        let neutral: Language
        if locale.hasPrefix("zh") || hasHanzi {
            neutral = .mandarin
        } else {
            neutral = locale == "auto" ? preferredLanguage ?? .english : .english
        }
        var language = neutral
        var pending = ""
        var result: [Segment] = []
        let punctuation = CharacterSet(charactersIn: ".,!?;:'’\"“”‘’()-，。！？；：、（）—…%％$¥￥/+-")
        func flush() throws {
            let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                guard value.contains(where: { $0.isLetter || $0.isNumber }) else {
                    throw CapabilityError.invalidRequest("No speakable Kokoro text")
                }
                if language == .english {
                    guard value.range(of: #"[0-9][.,][0-9]"#, options: .regularExpression) == nil else {
                        throw CapabilityError.invalidRequest("Spell out English decimal numbers")
                    }
                    for chunk in try chunks(value, tokenCount: { $0.count + 2 }) {
                        result.append(Segment(text: chunk, language: language))
                    }
                } else {
                    var chunk = ""
                    for char in value {
                        chunk.append(char)
                        if chunk.count >= 60 || "。！？；!?;".contains(char) {
                            result.append(Segment(text: chunk, language: language))
                            chunk = ""
                        }
                    }
                    if !chunk.isEmpty {
                        if !chunk.contains(where: { $0.isLetter || $0.isNumber }), let previous = result.last {
                            result[result.count - 1] = Segment(text: previous.text + chunk, language: previous.language)
                        } else {
                            result.append(Segment(text: chunk, language: language))
                        }
                    }
                }
            }
            pending = ""
        }
        for scalar in text.unicodeScalars {
            let next: Language?
            if isHanzi(scalar) {
                next = .mandarin
            } else if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
                next = .english
            } else if (48...57).contains(scalar.value) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || punctuation.contains(scalar)
            {
                next = nil
            } else {
                throw CapabilityError.invalidRequest("Unsupported Kokoro character or language")
            }
            if let next, next != language {
                // Leading neutral symbols (such as a price) belong to the first spoken run.
                if pending.contains(where: { $0.isLetter }) { try flush() }
                language = next
            }
            pending.unicodeScalars.append(scalar)
        }
        try flush()
        guard !result.isEmpty, result.count <= 32 else {
            throw CapabilityError.invalidRequest("Too many Kokoro segments")
        }
        return result
    }

    static func isHanzi(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            || (0x20000...0x2FA1F).contains(scalar.value)
    }

    static func validate(text: String, locale: String) throws { _ = try segments(text: text, locale: locale) }

    /// Split English at word boundaries; no truncation or splitting a word.
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
}
