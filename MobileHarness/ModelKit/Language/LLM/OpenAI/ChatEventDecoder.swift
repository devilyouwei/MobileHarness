import Foundation
import ModelKit

/// Incremental SSE framing, bounded before UTF-8 decoding (including unterminated lines).
struct ChatEventDecoder {
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
        guard delta["tool_calls"] == nil, delta["function_call"] == nil,
            delta["refusal"] == nil || delta["refusal"] is NSNull
        else { throw OpenAIChatError.unsupportedOutput }
        var events: [ChatEvent] = []
        if let content = delta["content"], !(content is NSNull) {
            guard let text = content as? String else { throw OpenAIChatError.invalidResponse }
            if !text.isEmpty { events.append(.text(text)) }
        }
        if let reason = choice["finish_reason"], !(reason is NSNull) {
            switch reason as? String {
            case "stop": events.append(.finished(.stop))
            case "length": events.append(.finished(.lengthLimit))
            default: throw OpenAIChatError.unsupportedOutput
            }
            finished = true
        }
        return events
    }
}
