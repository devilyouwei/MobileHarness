import Foundation
import ModelKit

enum MossInput {
    static func chineseVoice(text: String, locale: String) throws -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2048 else {
            throw CapabilityError.invalidRequest("MOSS text must contain 1...2048 UTF-8 bytes")
        }
        let language = locale.lowercased().replacingOccurrences(of: "_", with: "-")
        guard ["auto", "zh", "zh-cn", "zh-hans", "zh-tw", "zh-hant", "en", "en-us", "en-gb"].contains(language) else {
            throw CapabilityError.invalidRequest("MOSS currently enables Chinese and English voices only")
        }
        if language != "auto" { return language.hasPrefix("zh") }
        return text.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0x20000...0x2FA1F).contains($0.value)
        }
    }
}
