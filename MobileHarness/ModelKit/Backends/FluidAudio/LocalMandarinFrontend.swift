@preconcurrency import CoreML
import FluidAudio
import Foundation

/// The published g2pW graph requires six inputs and produces `probs`.
/// FluidAudio's four-input `MandarinG2pwModel` does not match this export.
actor LocalMandarinFrontend {
    enum Failure: Error { case incompatibleGraph, textTooLong, invalidProbabilities }
    private let model: MLModel
    private let tokenizer: MandarinBertTokenizer
    private let catalog: MandarinPolyphoneCatalog
    private let dict: MandarinPinyinDict
    private let frontend: MandarinG2P

    init(base: URL) throws {
        let assets = base.appendingPathComponent("assets")
        dict = try MandarinPinyinDict.load(
            singlesURL: assets.appendingPathComponent("pinyin_single.bin"),
            phrasesURL: assets.appendingPathComponent("pinyin_phrases.bin"))
        let hmm = MandarinJiebaHmm(tables: try MandarinJiebaHmmTables.load(directory: assets))
        frontend = MandarinG2P(dict: dict, jiebaHmm: hmm)
        let g2pw = base.appendingPathComponent("g2pw")
        tokenizer = try MandarinBertTokenizer.load(vocabURL: g2pw.appendingPathComponent("vocab.txt"))
        catalog = try MandarinPolyphoneCatalog.load(fileURL: g2pw.appendingPathComponent("POLYPHONIC_CHARS.txt"))
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: g2pw.appendingPathComponent("g2pw.mlmodelc"), configuration: config)
        guard
            Set(model.modelDescription.inputDescriptionsByName.keys)
                == Set([
                    "input_ids", "attention_mask", "token_type_ids", "phoneme_mask", "char_ids", "position_ids",
                ]),
            model.modelDescription.outputDescriptionsByName["probs"]?.multiArrayConstraint?.shape.last?.intValue
                == catalog.labels.count
        else { throw Failure.incompatibleGraph }
    }

    func phonemize(_ text: String) async throws -> String {
        let normalized = MandarinNumberNormalizer.normalize(text)
        let chars = Array(normalized)
        guard chars.count <= 510 else { throw Failure.textTooLong }
        let encoded = tokenizer.encode(chars: chars)
        // Match known phrases first, like the dictionary frontend. Only ambiguous
        // single characters outside those phrases need a contextual classifier.
        var targets: [Int] = []
        var index = 0
        while index < chars.count {
            var matched = 0
            let longest = min(dict.maxPhraseCharCount, chars.count - index)
            if longest >= 2 {
                for count in stride(from: longest, through: 2, by: -1) {
                    if dict.phrases[String(chars[index..<index + count])] != nil {
                        matched = count
                        break
                    }
                }
            }
            if matched > 0 {
                index += matched
                continue
            }
            if let candidates = catalog.candidates(for: chars[index]), candidates.count > 1 {
                targets.append(index)
            }
            index += 1
        }
        var output = ""
        var start = 0
        for target in targets {
            try Task.checkCancellation()
            if start < target { output += try await frontend.phonemize(String(chars[start..<target])) }
            output += try await predict(
                char: chars[target], position: encoded.tokenPositionForChar[target], encoded: encoded)
            start = target + 1
        }
        if start < chars.count { output += try await frontend.phonemize(String(chars[start...])) }
        return output
    }

    private func predict(char: Character, position: Int, encoded: MandarinBertTokenizer.Encoded) async throws -> String
    {
        guard let charID = catalog.charIndex[char], let candidates = catalog.candidates(for: char) else {
            throw Failure.invalidProbabilities
        }
        let mask = try MLMultiArray(shape: [1, NSNumber(value: catalog.labels.count)], dataType: .float32)
        for i in 0..<mask.count { mask[i] = 0 }
        for i in candidates { mask[i] = 1 }
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": ints(encoded.inputIds),
            "attention_mask": ints(encoded.attentionMask),
            "token_type_ids": ints(encoded.tokenTypeIds),
            "phoneme_mask": mask,
            "char_ids": ints([Int32(charID)], vector: true),
            "position_ids": ints([Int32(position)], vector: true),
        ])
        let result = try await model.prediction(from: inputs)
        try Task.checkCancellation()
        guard let probabilities = result.featureValue(for: "probs")?.multiArrayValue,
            probabilities.count == catalog.labels.count,
            candidates.allSatisfy({ probabilities[$0].floatValue.isFinite }),
            let best = candidates.max(by: { probabilities[$0].floatValue < probabilities[$1].floatValue })
        else { throw Failure.invalidProbabilities }
        let label = catalog.labels[best]
        // This export's labels already contain tone digits; do not append a second tone.
        return label.last?.isNumber == true ? label : MandarinPolyphoneCatalog.toneDigitForm(label)
    }

    private func ints(_ values: [Int32], vector: Bool = false) throws -> MLMultiArray {
        let shape = vector ? [values.count] : [1, values.count]
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
        for (i, value) in values.enumerated() { array[i] = NSNumber(value: value) }
        return array
    }
}
