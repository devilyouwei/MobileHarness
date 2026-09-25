import Foundation
import ModelKit

/// Decode-only BPE vocabulary. This artifact uses Metaspace, not ByteLevel or ByteFallback.
struct NemotronTokenizer: Sendable {
    private let vocabulary: [Int: String]
    init(url: URL) throws {
        struct File: Decodable {
            struct Model: Decodable {
                let type: String
                let vocab: [String: Int]
            }
            struct Decoder: Decodable {
                let type: String
                let replacement: String
                let prependScheme: String
                enum CodingKeys: String, CodingKey {
                    case type, replacement
                    case prependScheme = "prepend_scheme"
                }
            }
            let model: Model
            let decoder: Decoder
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.model.type == "BPE", file.decoder.type == "Metaspace",
            file.decoder.replacement == "▁", file.decoder.prependScheme == "always",
            file.model.vocab.count == 13_087, Set(file.model.vocab.values) == Set(0..<13_087)
        else { throw CapabilityError.invalidRequest("Unsupported Nemotron tokenizer schema") }
        vocabulary = Dictionary(uniqueKeysWithValues: file.model.vocab.map { ($0.value, $0.key) })
    }
    func decode(tokens: [Int]) -> String {
        var text = tokens.compactMap { vocabulary[$0] }.joined().replacingOccurrences(of: "▁", with: " ")
        if text.hasPrefix(" ") { text.removeFirst() }
        return text
    }
}
