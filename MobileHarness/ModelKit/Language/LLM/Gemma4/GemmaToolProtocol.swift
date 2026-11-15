import CoreFoundation
import Foundation
import ModelKit
import Synchronization

/// Converts the neutral OpenAI-style contract to Gemma's native tool dialect.
/// No tools execute here. A complete validated generation is required before publishing calls.
enum GemmaToolProtocol {
    static let quote = "<|\"|>"
    static func enabled(_ request: ChatRequest) -> Bool {
        !request.tools.isEmpty || request.messages.contains { !$0.toolCalls.isEmpty || $0.role == .tool }
    }

    static func failure(_ reason: String) -> CapabilityError {
        .invalidRequest("Gemma tool protocol: \(reason)")
    }

    static func identifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
            value.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "_-.$".unicodeScalars.contains($0)
            })
        else { throw failure("invalid identifier") }
        return value
    }

    static func string(_ value: String) throws -> String {
        guard !value.contains("<|"), !value.contains("|>") else {
            throw failure("reserved token in tool data")
        }
        return quote + value + quote
    }

    static func object(_ json: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw failure("arguments must be a JSON object")
        }
        return result
    }

    static func encode(_ value: Any, depth: Int = 0) throws -> String {
        guard depth < 64 else { throw failure("nesting limit exceeded") }
        if let value = value as? String { return try string(value) }
        if value is NSNull { return "null" }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            return value.stringValue
        }
        if let value = value as? [String: Any] {
            return "{"
                + (try value.keys.sorted().map {
                    try ((try? identifier($0)) ?? string($0)) + ":" + encode(value[$0] ?? NSNull(), depth: depth + 1)
                }).joined(separator: ",") + "}"
        }
        if let value = value as? [Any] {
            return "[" + (try value.map { try encode($0, depth: depth + 1) }).joined(separator: ",") + "]"
        }
        throw failure("unsupported value")
    }

    /// Schema types use uppercase in Gemma declarations; property names and enum values do not.
    static func schema(_ value: [String: Any]) -> [String: Any] {
        var result = value
        if let type = value["type"] as? String { result["type"] = type.uppercased() }
        if let types = value["type"] as? [String] { result["type"] = types.map { $0.uppercased() } }
        if let properties = value["properties"] as? [String: [String: Any]] {
            result["properties"] = properties.mapValues(schema)
        }
        for key in ["items", "additionalProperties"] {
            if let child = value[key] as? [String: Any] { result[key] = schema(child) }
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let children = value[key] as? [[String: Any]] { result[key] = children.map(schema) }
        }
        return result
    }

    static func render(_ request: ChatRequest) throws -> String {
        var result = "<bos><|turn>system\n"
        result += request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        if case .required(let name) = request.toolChoice {
            result += "\nYou must call the function \(try identifier(name)) in this response."
        }
        for tool in request.tools {
            guard let root = try JSONSerialization.jsonObject(with: tool.declaration) as? [String: Any],
                let function = root["function"] as? [String: Any],
                let parameters = function["parameters"] as? [String: Any]
            else { throw failure("invalid declaration") }
            result +=
                "<|tool>declaration:\(try identifier(tool.name)){description:"
                + (try string(function["description"] as? String ?? ""))
                + ",parameters:" + (try encode(schema(parameters))) + "}<tool|>"
        }
        result += "<turn|>\n"
        let messages = request.messages.filter { $0.role != .system }
        var modelOpen = false
        var names: [String: String] = [:]
        for message in messages {
            if message.role == .tool {
                guard let id = message.toolCallID, let name = names.removeValue(forKey: id) else {
                    throw failure("unmatched tool result")
                }
                result +=
                    "<|tool_response>response:\(try identifier(name)){value:"
                    + (try string(message.content)) + "}<tool_response|>"
                continue
            }
            if message.role != .assistant || !modelOpen {
                if modelOpen { result += "<turn|>\n" }
                result += "<|turn>\(message.role == .assistant ? "model" : "user")\n"
            }
            modelOpen = message.role == .assistant
            for call in message.toolCalls {
                names[call.id] = call.name
                result +=
                    "<|tool_call>call:\(try identifier(call.name))"
                    + (try encode(object(call.argumentsJSON))) + "<tool_call|>"
            }
            result += message.content
            if !modelOpen { result += "<turn|>\n" }
        }
        guard names.isEmpty else { throw failure("missing tool results") }
        if !modelOpen { result += "<|turn>model\n" }
        return result
    }

    struct Output {
        let text: String
        let calls: [ChatToolCall]
    }

    static func parse(_ text: String, request: ChatRequest, stopped: Bool) throws -> Output {
        var parser = Parser(text)
        var prose = ""
        var calls: [ChatToolCall] = []
        while !parser.rest.isEmpty {
            if parser.take("<|tool_call>") {
                guard stopped, parser.take("call:"), calls.count < 128 else {
                    throw failure("incomplete tool generation")
                }
                let name = try parser.key(until: "{")
                guard request.tools.contains(where: { $0.name == name }) else {
                    throw failure("undeclared function")
                }
                guard let arguments = try parser.value() as? [String: Any], parser.take("<tool_call|>") else {
                    throw failure("invalid tool arguments or closing marker")
                }
                let data = try JSONSerialization.data(
                    withJSONObject: arguments, options: [.sortedKeys, .fragmentsAllowed])
                calls.append(
                    .init(
                        id: "call_" + UUID().uuidString, name: name,
                        argumentsJSON: String(decoding: data, as: UTF8.self)))
            } else {
                // Never forward partial protocol markers or accept text after a tool call.
                if !calls.isEmpty, parser.rest.first?.isWhitespace == true {
                    parser.rest.removeFirst()
                    continue
                }
                guard !parser.rest.hasPrefix("<|"), !parser.rest.hasPrefix("<tool"),
                    parser.rest != "<", calls.isEmpty
                else {
                    throw failure("unexpected or incomplete tool output")
                }
                prose.append(parser.rest.removeFirst())
            }
        }
        guard !calls.isEmpty || !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("empty generation")
        }
        if case .required(let name) = request.toolChoice,
            calls.isEmpty || calls.contains(where: { $0.name != name })
        {
            throw failure("required function was not called")
        }
        return Output(text: prose, calls: calls)
    }

    /// Recursive bounded parser: strings are delimited by Gemma tokens, not JSON escaping.
    private struct Parser {
        var rest: Substring
        init(_ text: String) { rest = text[...] }
        mutating func whitespace() {
            while let first = rest.first, first.isWhitespace { rest.removeFirst() }
        }
        mutating func take(_ token: String) -> Bool {
            guard rest.hasPrefix(token) else { return false }
            rest = rest.dropFirst(token.count)
            return true
        }
        mutating func key(until delimiter: Character = ":") throws -> String {
            whitespace()
            if rest.hasPrefix(quote) {
                let key = try stringValue()
                whitespace()
                guard rest.first == delimiter else { throw failure("missing delimiter") }
                return key
            }
            guard let end = rest.firstIndex(of: delimiter) else { throw failure("missing key delimiter") }
            let key = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            rest = rest[end...]
            return try identifier(key)
        }
        mutating func stringValue() throws -> String {
            guard take(quote), let end = rest.range(of: quote) else { throw failure("unterminated string") }
            let value = String(rest[..<end.lowerBound])
            rest = rest[end.upperBound...]
            return value
        }
        mutating func value(depth: Int = 0) throws -> Any {
            guard depth < 64 else { throw failure("nesting limit exceeded") }
            whitespace()
            if rest.hasPrefix(quote) { return try stringValue() }
            if take("{") {
                var object: [String: Any] = [:]
                whitespace()
                if take("}") { return object }
                repeat {
                    let name = try key()
                    guard take(":"), object[name] == nil else { throw failure("duplicate key") }
                    object[name] = try value(depth: depth + 1)
                    whitespace()
                    if take("}") { return object }
                    guard take(",") else { throw failure("invalid object") }
                } while true
            }
            if take("[") {
                var values: [Any] = []
                whitespace()
                if take("]") { return values }
                repeat {
                    values.append(try value(depth: depth + 1))
                    whitespace()
                    if take("]") { return values }
                    guard take(",") else { throw failure("invalid array") }
                } while true
            }
            let end = rest.firstIndex { ",}]".contains($0) || $0.isWhitespace } ?? rest.endIndex
            let literal = String(rest[..<end])
            rest = rest[end...]
            guard !literal.isEmpty,
                let scalar = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed]),
                scalar is NSNumber || scalar is NSNull
            else { throw failure("invalid scalar") }
            return scalar
        }
    }
}

/// Owned by one generation task; bounded independently of the downstream event queue.
final class GemmaToolOutputBuffer: Sendable {
    private let state = Mutex("")
    func append(_ delta: String) throws {
        try state.withLock {
            guard $0.utf8.count + delta.utf8.count <= 262144 else { throw GemmaLanguageError.outputTooLarge }
            $0 += delta
        }
    }
    var text: String { state.withLock { $0 } }
}
