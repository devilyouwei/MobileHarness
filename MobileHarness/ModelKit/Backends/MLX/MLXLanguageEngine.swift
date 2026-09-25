import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

public struct MLXLanguageTurn: Sendable {
    public let role: String
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Local weights only. Mutable generation/cache state belongs to one invocation.
public actor MLXLanguageEngine {
    private let container: ModelContainer
    private var active = false

    /// Process-wide MLX allocator configuration; invoke once before loading any MLX model.
    public static func configureCache(limitBytes: Int) throws {
        guard limitBytes >= 0 else { throw MLXLanguageError.invalidCacheLimit }
        Memory.cacheLimit = limitBytes
        Memory.clearCache()
    }

    public init(directory: URL) async throws {
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
    }

    public func tokenize(_ messages: [MLXLanguageTurn]) async throws -> [Int] {
        let tokenizer = await container.tokenizer
        return try tokenizer.applyChatTemplate(
            messages: messages.map { ["role": $0.role, "content": $0.content] }, tools: nil,
            additionalContext: ["enable_thinking": false])
    }

    /// A pull iterator avoids an extra unbounded AsyncStream between MLX and the bounded capability stream.
    public func generate(
        tokens: [Int], maximumTokens: Int, temperature: Double, stopTokens: Set<Int>,
        emit: @escaping @Sendable (String) throws -> Void
    ) async throws -> Bool {
        guard !active else { throw MLXLanguageError.busy }
        active = true
        defer { active = false }
        return try await container.perform { context in
            try Task.checkCancellation()
            // Synchronize in all exit paths before the provider releases the model lease.
            defer { Stream().synchronize() }
            var iterator = try TokenIterator(
                input: LMInput(tokens: MLXArray(tokens)), model: context.model,
                parameters: GenerateParameters(
                    maxTokens: maximumTokens, temperature: Float(temperature), topP: 0.8, topK: 20,
                    prefillStepSize: 128))
            var generated: [Int] = []
            var previous = ""
            while generated.count < maximumTokens {
                try Task.checkCancellation()
                guard let token = iterator.next() else { return false }
                if stopTokens.contains(token) { return true }
                generated.append(token)
                var decoded = context.tokenizer.decode(tokenIds: generated)
                while decoded.last == "\u{FFFD}" { decoded.removeLast() }
                guard decoded.hasPrefix(previous) else { throw MLXLanguageError.nonMonotonicText }
                let delta = String(decoded.dropFirst(previous.count))
                previous = decoded
                if !delta.isEmpty { try emit(delta) }
            }
            try Task.checkCancellation()
            return false
        }
    }
}

public enum MLXLanguageError: Error { case busy, nonMonotonicText, invalidCacheLimit }

/// Bridges the existing pinned Swift tokenizer dependency to MLX's tokenizer protocol.
struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let files = LanguageModelConfigurationFromHub(modelFolder: directory)
        guard var config = try await files.tokenizerConfig else { throw Tokenizers.TokenizerError.missingConfig }
        let data = try await files.tokenizerData
        guard var values = config.dictionary() else { throw Tokenizers.TokenizerError.missingConfig }
        if config.tokenizerClass.string() == "TokenizersBackend" {
            guard data.model.type.string() == "BPE" else {
                throw Tokenizers.TokenizerError.unsupportedTokenizer("TokenizersBackend requires BPE")
            }
            values["tokenizer_class"] = .init("PreTrainedTokenizerFast")
        }
        // Match Hugging Face's Jinja keep_trailing_newline=false without trimming output content.
        if let template = values["chat_template"]?.string(), template.hasSuffix("\n") {
            values["chat_template"] = .init(String(template.dropLast()))
        }
        config = Config(values)
        return TokenizerBridge(base: try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: data, strict: true))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try base.applyChatTemplate(
            messages: messages.map { $0.mapValues { $0 as Any } }, tools: tools?.map { $0.mapValues { $0 as Any } },
            additionalContext: additionalContext?.mapValues { $0 as Any })
    }
}
