import CoreFoundation
import Foundation
import ModelKit

/// Incremental SSE framing. Only the current frame is retained; completed frames release their bytes.
struct ChatEventDecoder {
    let toolNames: [String: String]
    private let timing: ChatTiming?
    init(toolNames: [String: String] = [:], timing: ChatTiming? = nil) {
        self.toolNames = toolNames
        self.timing = timing
    }
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
    private var previousCR = false
    private(set) var finished = false
    private(set) var done = false
    private var receivedUsage = false
    private var eventType: String?

    private func failure(
        _ reason: ChatFailureDiagnostic.Reason, stage: ChatFailureDiagnostic.Stage,
        field: String? = nil, index: Int? = nil, name: String? = nil
    ) -> OpenAIChatError {
        .responseFailure(
            .init(
                reason, stage: stage, event: eventType, field: field, outputIndex: index, toolName: name,
                declaredNames: reason == .undeclaredTool ? toolNames.keys.sorted() : []))
    }

    mutating func consume(_ byte: UInt8) throws -> [ChatEvent] {
        if byte == 10, previousCR {
            previousCR = false
            return []
        }
        previousCR = byte == 13
        if byte == 10 || byte == 13 { return try endLine() }
        line.append(byte)
        return []
    }

    private mutating func endLine() throws -> [ChatEvent] {
        guard let text = String(bytes: line, encoding: .utf8) else {
            throw failure(.malformedEvent, stage: .framing, field: "utf8")
        }
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
        guard !done, !finished else {
            throw failure(.invalidCompletion, stage: .completion, field: "eventAfterTerminal")
        }
        eventType = nil
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { throw failure(.malformedEvent, stage: .event, field: "type") }
        eventType = type
        switch type {
        case "response.output_text.delta":
            guard let text = object["delta"] as? String else {
                throw failure(.invalidText, stage: .event, field: "delta")
            }
            return Self.textEvents(text)
        case "response.output_item.added":
            let (index, item) = try outputItem(object)
            guard let type = item["type"] as? String else {
                throw failure(.invalidItem, stage: .event, field: "item.type", index: index)
            }
            if type == "function_call" {
                guard calls[index] == nil else {
                    throw failure(.toolSequence, stage: .toolStart, field: "output_index", index: index)
                }
                guard let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 512 else {
                    throw failure(.invalidToolIdentity, stage: .toolStart, field: "item.id", index: index)
                }
                guard let callID = item["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= 512 else {
                    throw failure(.invalidToolIdentity, stage: .toolStart, field: "call_id", index: index)
                }
                guard let name = item["name"] as? String, !name.isEmpty else {
                    throw failure(.invalidToolIdentity, stage: .toolStart, field: "name", index: index)
                }
                guard toolNames[name] != nil else {
                    throw failure(.undeclaredTool, stage: .toolStart, field: "name", index: index, name: name)
                }
                calls[index] = Pending(itemID: id, callID: callID, name: name)
            } else if type == "reasoning" {
                try validateReasoning(item)
            } else if type != "message" {
                throw failure(.unsupportedOutput, stage: .event, field: "item.type")
            }
            return []
        case "response.function_call_arguments.delta":
            guard let index = object["output_index"] as? Int, var call = calls[index], call.completed == nil else {
                throw failure(
                    .toolSequence, stage: .toolArguments, field: "output_index", index: object["output_index"] as? Int)
            }
            guard object["item_id"] as? String == call.itemID else {
                throw failure(
                    .invalidToolIdentity, stage: .toolArguments, field: "item_id", index: index, name: call.name)
            }
            guard let delta = object["delta"] as? String else {
                throw failure(
                    .invalidToolArguments, stage: .toolArguments, field: "delta", index: index, name: call.name)
            }
            call.arguments += delta
            calls[index] = call
            timing?.recordToolArguments(delta)
            return []
        case "response.output_item.done":
            let (index, item) = try outputItem(object)
            if item["type"] as? String == "function_call" {
                guard var pending = calls[index], pending.completed == nil else {
                    throw failure(.toolSequence, stage: .toolEnd, field: "output_index", index: index)
                }
                for (field, expected) in [("id", pending.itemID), ("call_id", pending.callID), ("name", pending.name)] {
                    guard item[field] as? String == expected else {
                        throw failure(
                            .invalidToolIdentity, stage: .toolEnd, field: field, index: index,
                            name: item["name"] as? String)
                    }
                }
                guard let arguments = item["arguments"] as? String, arguments == pending.arguments else {
                    throw failure(
                        .toolArgumentsMismatch, stage: .toolEnd, field: "arguments", index: index, name: pending.name)
                }
                pending.completed = try functionCall(item, index: index)
                calls[index] = pending
            } else {
                try validateNonCallItem(item)
            }
            return []
        case "response.completed", "response.incomplete":
            guard let response = object["response"] as? [String: Any],
                response["status"] as? String == (type == "response.completed" ? "completed" : "incomplete"),
                let output = response["output"] as? [[String: Any]], output.count <= 128
            else { throw failure(.invalidCompletion, stage: .completion, field: "response.status-or-output") }
            var completed: [ChatToolCall] = []
            var ids: Set<String> = []
            for (index, item) in output.enumerated() {
                if item["type"] as? String == "function_call" {
                    let call = try functionCall(item, index: index)
                    guard calls[index]?.completed == call, ids.insert(call.id).inserted else {
                        throw failure(
                            .toolSequence, stage: .completion, field: "output", index: index,
                            name: item["name"] as? String)
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
                else { throw failure(.invalidUsage, stage: .usage, field: "usage") }
                receivedUsage = true
                let details: [String: Any]
                if let rawDetails = usage["input_tokens_details"], !(rawDetails is NSNull) {
                    guard let object = rawDetails as? [String: Any] else {
                        throw failure(.invalidUsage, stage: .usage, field: "usage.input_tokens_details")
                    }
                    details = object
                } else {
                    details = [:]
                }
                func optionalCount(_ key: String) throws -> Int? {
                    guard let value = details[key], !(value is NSNull) else { return nil }
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                        let count = value as? Int, count >= 0, count <= input,
                        number.doubleValue == Double(count)
                    else { throw failure(.invalidUsage, stage: .usage, field: "usage.input_tokens_details." + key) }
                    return count
                }
                let cached = try optionalCount("cached_tokens")
                let written = try optionalCount("cache_write_tokens")
                guard (cached ?? 0) <= input - (written ?? 0) else {
                    throw failure(.invalidUsage, stage: .usage, field: "usage.input_tokens_details.cacheTotals")
                }
                events.append(
                    .usage(
                        try ChatTokenUsage(
                            input: input, generated: generated, total: total,
                            cachedInput: cached, cacheWriteInput: written)))
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
        case "response.reasoning_text.delta", "response.reasoning_text.done",
            "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done":
            let field = type.hasSuffix(".delta") ? "delta" : "text"
            guard let index = object["output_index"] as? Int, (0..<128).contains(index),
                let id = object["item_id"] as? String, !id.isEmpty, id.utf8.count <= 512,
                object[field] is String
            else { throw failure(.invalidReasoning, stage: .reasoning, field: "reasoningEvent") }
            if type.hasPrefix("response.reasoning_summary_") {
                try validateSummaryIndex(object)
            }
            // Reasoning is provider-private metadata, never public answer text or a native call.
            return []
        case "response.reasoning_summary_part.added", "response.reasoning_summary_part.done":
            guard let index = object["output_index"] as? Int, (0..<128).contains(index),
                let id = object["item_id"] as? String, !id.isEmpty, id.utf8.count <= 512,
                let part = object["part"] as? [String: Any],
                part["type"] as? String == "summary_text", part["text"] is String
            else { throw failure(.invalidReasoning, stage: .reasoning, field: "summaryPart") }
            try validateSummaryIndex(object)
            return []
        case "response.refusal.delta", "response.refusal.done":
            throw failure(.unsupportedOutput, stage: .event, field: "refusal")
        case "response.failed", "error":
            let providerFailure =
                (object["response"] as? [String: Any])?["error"] as? [String: Any]
                ?? object["error"] as? [String: Any] ?? object
            if let code = providerFailure["code"] as? String, !code.isEmpty, code.utf8.count <= 128,
                code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
            {
                throw OpenAIChatError.providerCode(code)
            }
            throw failure(.providerFailure, stage: .event, field: "error.code")
        case "response.created", "response.in_progress", "response.output_text.done",
            "response.content_part.added", "response.content_part.done", "response.function_call_arguments.done":
            return []
        default: throw failure(.unsupportedOutput, stage: .event, field: "type")
        }
    }

    /// Backpressure limits event size, not the provider's total output or SSE frame size.
    private static func textEvents(_ text: String) -> [ChatEvent] {
        if text.isEmpty { return [] }
        if text.utf8.count <= 32768 { return [.text(text)] }
        var result: [ChatEvent] = []
        var chunk = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            if bytes + count > 32768 {
                result.append(.text(chunk))
                chunk = ""
                bytes = 0
            }
            chunk.unicodeScalars.append(scalar)
            bytes += count
        }
        if !chunk.isEmpty { result.append(.text(chunk)) }
        return result
    }

    private func outputItem(_ object: [String: Any]) throws -> (Int, [String: Any]) {
        guard let index = object["output_index"] as? Int, (0..<128).contains(index),
            let item = object["item"] as? [String: Any]
        else { throw failure(.invalidItem, stage: .event, field: "output_index-or-item") }
        return (index, item)
    }

    private func functionCall(_ item: [String: Any], index: Int) throws -> ChatToolCall {
        guard let id = item["call_id"] as? String, !id.isEmpty, id.utf8.count <= 512 else {
            throw failure(.invalidToolIdentity, stage: .completion, field: "call_id", index: index)
        }
        guard let wireName = item["name"] as? String, !wireName.isEmpty else {
            throw failure(.invalidToolIdentity, stage: .completion, field: "name", index: index)
        }
        guard let name = toolNames[wireName] else {
            throw failure(.undeclaredTool, stage: .completion, field: "name", index: index, name: wireName)
        }
        guard let arguments = item["arguments"] as? String,
            (try? JSONDecoder().decode([String: String].self, from: Data(arguments.utf8))) != nil
        else {
            throw failure(.invalidToolArguments, stage: .toolEnd, field: "arguments", index: index, name: wireName)
        }
        return ChatToolCall(id: id, name: name, argumentsJSON: arguments)
    }

    private func validateNonCallItem(_ item: [String: Any]) throws {
        if item["type"] as? String == "reasoning" {
            try validateReasoning(item)
            return
        }
        guard item["type"] as? String == "message", let content = item["content"] as? [[String: Any]],
            content.allSatisfy({ $0["type"] as? String == "output_text" && $0["text"] is String })
        else { throw failure(.unsupportedOutput, stage: .completion, field: "output.content") }
    }

    private func validateSummaryIndex(_ object: [String: Any]) throws {
        guard let number = object["summary_index"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let index = object["summary_index"] as? Int, (0..<128).contains(index),
            number.doubleValue == Double(index)
        else { throw failure(.invalidReasoning, stage: .reasoning, field: "summary_index") }
    }

    private func validateReasoning(_ item: [String: Any]) throws {
        guard let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
            let summary = item["summary"] as? [[String: Any]], summary.count <= 128,
            summary.allSatisfy({ $0["type"] as? String == "summary_text" && $0["text"] is String })
        else { throw failure(.invalidReasoning, stage: .reasoning, field: "reasoningItem") }
    }
}
