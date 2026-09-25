import Foundation

/// Shared model-output interpreter. It owns one parser and sentence buffer per generation.
public struct AgentGenerator: Sendable {
    private let capabilities: CapabilityRegistry
    private let textActions: [String]
    private var parser = FunctionTokenParser()
    private var sentences = SentenceFunctionBuffer()
    private var textChannel: String?
    private var calls = 0
    private var closed = false

    public init(capabilities: CapabilityRegistry, textActions: [String]) throws {
        guard !textActions.isEmpty, textActions.count <= 8, Set(textActions).count == textActions.count,
            textActions.allSatisfy({ alias in capabilities.actions.contains { $0.alias == alias } })
        else { throw GenerationError.unknownCapability }
        self.capabilities = capabilities
        self.textActions = textActions
    }

    public mutating func append(_ fragment: String) throws -> [ActionCall] {
        try append(Data(fragment.utf8))
    }

    public mutating func append(_ bytes: Data) throws -> [ActionCall] {
        guard !closed else { throw GenerationError.closed }
        do { return try interpret(parser.append(bytes)) } catch {
            closed = true
            throw error
        }
    }

    public mutating func finish() throws -> [ActionCall] {
        guard !closed else { throw GenerationError.closed }
        do {
            var output = try interpret(parser.finish())
            output += try flush()
            closed = true
            return output
        } catch {
            closed = true
            throw error
        }
    }

    /// Literal tool results/demo text never become markup or executable model instructions.
    public static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private mutating func interpret(_ tokens: [FunctionToken]) throws -> [ActionCall] {
        var result: [ActionCall] = []
        for token in tokens {
            switch token {
            case .text(let text, let channel):
                if channel != textChannel {
                    result += try flush()
                    textChannel = channel
                }
                result += try mapText(sentences.append(text))
            case .boundary:
                result += try flush()
            case .action(let alias, let parameters, let channel):
                result += try flush()
                try reserve(1)
                result.append(try capabilities.resolveAction(alias, parameters: parameters, channel: channel))
            }
        }
        return result
    }

    private mutating func flush() throws -> [ActionCall] { try mapText(sentences.finish()) }

    private mutating func mapText(_ chunks: [String]) throws -> [ActionCall] {
        var output: [ActionCall] = []
        for chunk in chunks {
            try reserve(textActions.count)
            for alias in textActions {
                output.append(try capabilities.resolveAction(alias, parameters: ["text": chunk], channel: textChannel))
            }
        }
        return output
    }

    private mutating func reserve(_ count: Int) throws {
        guard calls + count <= 120 else { throw GenerationError.limitExceeded }
        calls += count
    }
}
