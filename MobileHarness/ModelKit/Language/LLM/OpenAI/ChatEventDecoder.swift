import CoreFoundation
import Foundation
import ModelKit

/// Incremental SSE framing, bounded before UTF-8 decoding (including unterminated lines).
struct ChatEventDecoder {
    let toolNames: [String: String]
    init(toolNames: [String: String] = [:]) { self.toolNames = toolNames }
    private struct Pending {
        let itemID: String
        let callID: String
        let name: String
        var arguments = ""
        var completed: ChatToolCall?
    }
    private var calls: [Int: Pending] = [:]
    private var line: [UInt8] = []
    private var data = ""
    private var total = 0
    private var previousCR = false
    private(set) var finished = false
    private(set) var done = false
    private var receivedUsage = false

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
        if payload == "[DONE]" {
            guard finished else { throw OpenAIChatError.truncatedStream }
            done = true
            return []
        }
        guard !done else { throw OpenAIChatError.invalidResponse }
        guard !finished,
            let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { throw OpenAIChatError.invalidResponse }
        switch type {
        case "response.output_text.delta":
            guard let text = object["delta"] as? String else { throw OpenAIChatError.invalidResponse }
            return text.isEmpty ? [] : [.text(text)]
        case "response.output_item.added":
            let (index, item) = try outputItem(object)
            guard let type = item["type"] as? String else { throw OpenAIChatError.invalidResponse }
            if type == "function_call" {
                guard calls[index] == nil, let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
                    let callID = item["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 512,
                    let name = item["name"] as? String, toolNames[name] != nil
                else { throw OpenAIChatError.invalidResponse }
                calls[index] = Pending(itemID: id, callID: callID, name: name)
            } else if type == "reasoning" {
                try validateReasoning(item)
            } else if type != "message" {
                throw OpenAIChatError.unsupportedOutput
            }
            return []
        case "response.function_call_arguments.delta":
            guard let index = object["output_index"] as? Int, var call = calls[index],
                call.completed == nil, object["item_id"] as? String == call.itemID,
                let delta = object["delta"] as? String
            else { throw OpenAIChatError.invalidResponse }
            call.arguments += delta
            guard call.arguments.utf8.count <= 4096 else { throw OpenAIChatError.responseTooLarge }
            calls[index] = call
            return []
        case "response.output_item.done":
            let (index, item) = try outputItem(object)
            if item["type"] as? String == "function_call" {
                guard var pending = calls[index], pending.completed == nil,
                    item["id"] as? String == pending.itemID,
                    item["call_id"] as? String == pending.callID,
                    item["name"] as? String == pending.name,
                    let arguments = item["arguments"] as? String,
                    arguments == pending.arguments
                else { throw OpenAIChatError.invalidResponse }
                pending.completed = try functionCall(item)
                calls[index] = pending
            } else {
                try validateNonCallItem(item)
            }
            return []
        case "response.completed", "response.incomplete":
            guard let response = object["response"] as? [String: Any],
                response["status"] as? String == (type == "response.completed" ? "completed" : "incomplete"),
                let output = response["output"] as? [[String: Any]], output.count <= 128
            else { throw OpenAIChatError.invalidResponse }
            var completed: [ChatToolCall] = []
            var ids: Set<String> = []
            for (index, item) in output.enumerated() {
                if item["type"] as? String == "function_call" {
                    let call = try functionCall(item)
                    guard calls[index]?.completed == call, ids.insert(call.id).inserted else {
                        throw OpenAIChatError.invalidResponse
                    }
                    completed.append(call)
                } else {
                    try validateNonCallItem(item)
                }
            }
            guard calls.count == completed.count else { throw OpenAIChatError.truncatedStream }
            var events: [ChatEvent] = []
            if let raw = response["usage"], !(raw is NSNull) {
                guard !receivedUsage, let usage = raw as? [String: Any],
                    let input = usage["input_tokens"] as? Int,
                    let generated = usage["output_tokens"] as? Int,
                    let total = usage["total_tokens"] as? Int,
                    input >= 0, generated >= 0, total >= 0,
                    ["input_tokens", "output_tokens", "total_tokens"].allSatisfy({ key in
                        guard let number = usage[key] as? NSNumber else { return false }
                        return CFGetTypeID(number) != CFBooleanGetTypeID()
                    })
                else { throw OpenAIChatError.invalidResponse }
                receivedUsage = true
                events.append(.usage(try ChatTokenUsage(input: input, generated: generated, total: total)))
            }
            if type == "response.incomplete" {
                guard completed.isEmpty,
                    (response["incomplete_details"] as? [String: Any])?["reason"] as? String == "max_output_tokens"
                else { throw OpenAIChatError.truncatedStream }
                events.append(.finished(.lengthLimit))
            } else {
                events += completed.map(ChatEvent.toolCall)
                events.append(.finished(completed.isEmpty ? .stop : .toolCalls))
            }
            finished = true
            return events
        case "response.reasoning_text.delta", "response.reasoning_text.done":
            let field = type == "response.reasoning_text.delta" ? "delta" : "text"
            guard let index = object["output_index"] as? Int, (0..<128).contains(index),
                let id = object["item_id"] as? String, !id.isEmpty, id.utf8.count <= 512,
                object[field] is String
            else { throw OpenAIChatError.invalidResponse }
            // Reasoning is provider-private metadata, never public answer text or a native call.
            return []
        case "response.refusal.delta", "response.refusal.done": throw OpenAIChatError.unsupportedOutput
        case "response.failed", "error":
            let failure =
                (object["response"] as? [String: Any])?["error"] as? [String: Any]
                ?? object["error"] as? [String: Any] ?? object
            if let code = failure["code"] as? String, !code.isEmpty, code.utf8.count <= 128,
                code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
            {
                throw OpenAIChatError.providerCode(code)
            }
            throw OpenAIChatError.invalidResponse
        case "response.created", "response.in_progress", "response.output_text.done",
            "response.content_part.added", "response.content_part.done", "response.function_call_arguments.done":
            return []
        default: throw OpenAIChatError.unsupportedOutput
        }
    }

    private func outputItem(_ object: [String: Any]) throws -> (Int, [String: Any]) {
        guard let index = object["output_index"] as? Int, (0..<128).contains(index),
            let item = object["item"] as? [String: Any]
        else { throw OpenAIChatError.invalidResponse }
        return (index, item)
    }

    private func functionCall(_ item: [String: Any]) throws -> ChatToolCall {
        guard let id = item["call_id"] as? String, !id.isEmpty, id.utf8.count <= 512,
            let wireName = item["name"] as? String, let name = toolNames[wireName],
            let arguments = item["arguments"] as? String, arguments.utf8.count <= 4096,
            (try? JSONDecoder().decode([String: String].self, from: Data(arguments.utf8))) != nil
        else { throw OpenAIChatError.invalidResponse }
        return ChatToolCall(id: id, name: name, argumentsJSON: arguments)
    }

    private func validateNonCallItem(_ item: [String: Any]) throws {
        if item["type"] as? String == "reasoning" {
            try validateReasoning(item)
            return
        }
        guard item["type"] as? String == "message", let content = item["content"] as? [[String: Any]],
            content.allSatisfy({ $0["type"] as? String == "output_text" && $0["text"] is String })
        else { throw OpenAIChatError.unsupportedOutput }
    }

    private func validateReasoning(_ item: [String: Any]) throws {
        guard let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
            let summary = item["summary"] as? [[String: Any]], summary.count <= 128,
            summary.allSatisfy({ $0["type"] as? String == "summary_text" && $0["text"] is String })
        else { throw OpenAIChatError.invalidResponse }
    }
}
