import Foundation
import ModelKit

/// Incremental SSE framing, bounded before UTF-8 decoding (including unterminated lines).
struct ChatEventDecoder {
    let toolNames: [String: String]
    init(toolNames: [String: String] = [:]) { self.toolNames = toolNames }
    private struct Pending {
        var id = ""
        var name = ""
        var arguments = ""
    }
    private var calls: [Int: Pending] = [:]
    private var line: [UInt8] = []
    private var data = ""
    private var total = 0
    private var previousCR = false
    private(set) var finished = false

    mutating func consume(_ byte: UInt8) throws -> [ChatEvent] {
        total += 1
        guard total <= 8 * 1024 * 1024 else { throw OpenAIChatError.responseTooLarge }
        if byte == 10, previousCR {
            previousCR = false
            return []
        }
        previousCR = byte == 13
        if byte == 10 || byte == 13 { return try endLine() }
        guard line.count < 65536 else { throw OpenAIChatError.responseTooLarge }
        line.append(byte)
        return []
    }

    private mutating func endLine() throws -> [ChatEvent] {
        guard let text = String(bytes: line, encoding: .utf8) else { throw OpenAIChatError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            guard !data.isEmpty else { return [] }
            let payload = data
            data = ""
            return try decode(payload)
        }
        if text.hasPrefix("data:") {
            var value = text.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            guard data.utf8.count + value.utf8.count + 1 <= 65536 else {
                throw OpenAIChatError.responseTooLarge
            }
            if !data.isEmpty { data += "\n" }
            data += value
        }
        return []
    }

    private mutating func decode(_ payload: String) throws -> [ChatEvent] {
        guard payload != "[DONE]" else { throw OpenAIChatError.truncatedStream }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            object["error"] == nil, let choices = object["choices"] as? [[String: Any]]
        else { throw OpenAIChatError.invalidResponse }
        if choices.isEmpty { return [] }  // Optional usage event.
        guard choices.count == 1, let choice = choices.first, choice["index"] as? Int == 0,
            let delta = choice["delta"] as? [String: Any]
        else { throw OpenAIChatError.invalidResponse }
        guard delta["function_call"] == nil,
            delta["refusal"] == nil || delta["refusal"] is NSNull
        else { throw OpenAIChatError.unsupportedOutput }
        if let raw = delta["tool_calls"], !(raw is NSNull) {
            guard let fragments = raw as? [[String: Any]], !toolNames.isEmpty,
                fragments.count <= 128 else { throw OpenAIChatError.unsupportedOutput }
            for fragment in fragments {
                guard let index = fragment["index"] as? Int, (0..<128).contains(index),
                    fragment["type"] == nil || fragment["type"] is NSNull || fragment["type"] as? String == "function",
                    let function = fragment["function"] as? [String: Any]
                else { throw OpenAIChatError.invalidResponse }
                var call = calls[index] ?? Pending()
                for (key, target) in [("id", 0), ("name", 1), ("arguments", 2)] {
                    let value = target == 0 ? fragment[key] : function[key]
                    if let value, !(value is NSNull) {
                        guard let text = value as? String else { throw OpenAIChatError.invalidResponse }
                        switch target {
                        case 0: call.id += text
                        case 1: call.name += text
                        default: call.arguments += text
                        }
                    }
                }
                guard call.id.utf8.count <= 512, call.name.utf8.count <= 64,
                    call.arguments.utf8.count <= 4096 else { throw OpenAIChatError.responseTooLarge }
                calls[index] = call
            }
        }
        var events: [ChatEvent] = []
        if let content = delta["content"], !(content is NSNull) {
            guard let text = content as? String else { throw OpenAIChatError.invalidResponse }
            if !text.isEmpty { events.append(.text(text)) }
        }
        if let reason = choice["finish_reason"], !(reason is NSNull) {
            switch reason as? String {
            case "stop":
                guard calls.isEmpty else { throw OpenAIChatError.invalidResponse }
                events.append(.finished(.stop))
            case "tool_calls":
                guard !calls.isEmpty else { throw OpenAIChatError.invalidResponse }
                var ids: Set<String> = []
                for index in calls.keys.sorted() {
                    guard let call = calls[index], !call.id.isEmpty, ids.insert(call.id).inserted,
                        let name = toolNames[call.name],
                        (try? JSONDecoder().decode([String: String].self, from: Data(call.arguments.utf8))) != nil
                    else { throw OpenAIChatError.invalidResponse }
                    events.append(.toolCall(ChatToolCall(id: call.id, name: name, argumentsJSON: call.arguments)))
                }
                events.append(.finished(.toolCalls))
            case "length":
                guard calls.isEmpty else { throw OpenAIChatError.truncatedStream }
                events.append(.finished(.lengthLimit))
            default: throw OpenAIChatError.unsupportedOutput
            }
            finished = true
        }
        return events
    }
}
