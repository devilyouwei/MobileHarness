import AgentCore
import Foundation
import ModelKit

/// Assistant-owned projection and decoding. Resource selection, deadlines and adoption belong to the caller.
enum AssistantDecisionProtocol: Sendable {
    enum Mode: String, Codable, Sendable {
        case jev, tool, text

        static func selectChat(modelID: String?, supportsTools: Bool) -> Self {
            guard supportsTools else { return .text }
            return switch modelID {
            // Matched Decision benchmark: more correct responses within 500 ms than Tool.
            case "qwen3.7-flash", "qwen3.8-flash": .text
            // Gemma Text was more accurate and reliable. Both modes exceeded the local budget.
            case "gemma4-e2b": .text
            default: .tool
            }
        }
    }

    case jev(any DecisionCapability)
    case tool(any ChatCapability)
    case text(any ChatCapability)

    static func chat(_ model: any ChatCapability, modelID: String?) async -> Self {
        let mode = Mode.selectChat(modelID: modelID, supportsTools: await model.supportsToolCalls)
        return mode == .tool ? .tool(model) : .text(model)
    }

    func classify(
        _ prompt: InputDecisionSnapshot.Prompt,
        record: @Sendable (String) -> Void = { _ in }
    ) async throws -> InputDisposition {
        switch self {
        case .jev(let model): try await JEV.classify(prompt, model: model, record: record)
        case .tool(let model): try await Tool.classify(prompt, model: model, record: record)
        case .text(let model): try await Text.classify(prompt, model: model, record: record)
        }
    }

    private static func label(_ value: String, in prompt: InputDecisionSnapshot.Prompt) throws -> InputDisposition {
        guard let index = prompt.labels.firstIndex(of: value) else {
            throw CapabilityError.invalidRequest("Decision expected exactly one digit")
        }
        return prompt.choices[index]
    }

    enum JEV {
        static func request(_ prompt: InputDecisionSnapshot.Prompt) throws -> DecisionRequest {
            try .init(
                text: prompt.background, candidates: prompt.labels,
                context: prompt.context, instructions: prompt.latest)
        }

        static func classify(
            _ prompt: InputDecisionSnapshot.Prompt, model: any DecisionCapability, record: @Sendable (String) -> Void
        ) async throws -> InputDisposition {
            let request = try request(prompt)
            let options = zip(["A", "B", "C", "D"], prompt.labels).map { "\($0): \($1)" }.joined(separator: "\n")
            record("JEV\n\n" + prompt.text + "\n\nOptions\n" + options)
            let session = try await model.decide(request)
            return try await session.withCleanup {
                var result: InputDisposition?
                for try await value in session.events {
                    guard result == nil, case .selected(let choice, _) = value.decision else {
                        throw CapabilityError.invalidRequest("Invalid JEV candidate selection")
                    }
                    result = try label(choice, in: prompt)
                }
                guard let result else { throw CapabilityError.invalidRequest("Missing JEV candidate") }
                return result
            }
        }
    }

    private enum Tool {
        static let name = "classify_input"

        static func classify(
            _ prompt: InputDecisionSnapshot.Prompt, model: any ChatCapability, record: @Sendable (String) -> Void
        ) async throws -> InputDisposition {
            let definition = try JSONSerialization.data(
                withJSONObject: [
                    "type": "function",
                    "function": [
                        "name": name,
                        "description": try AgentPrompts.text("Assistant/InputDecision", "toolDescription"),
                        "parameters": [
                            "type": "object",
                            "properties": ["action": ["type": "string", "enum": prompt.choices.map(\.rawValue)]],
                            "required": ["action"], "additionalProperties": false,
                        ],
                    ],
                ], options: [.sortedKeys])
            let request = try ChatRequest(
                messages: [.init(role: .user, content: prompt.text)], context: prompt.context,
                maximumOutputTokens: 128, temperature: 0, tools: [ChatToolDefinition(declaration: definition)],
                toolChoice: .required(name: name))
            record(
                "Tool\n\nuser\n" + prompt.text + "\n\nTool\n" + String(decoding: definition, as: UTF8.self)
                    + "\n\ntool_choice: \(request.toolChoice)\nmaximum_output_tokens: 128")
            let session = try await model.chat(request)
            return try await session.withCleanup {
                var result: InputDisposition?
                var finished = false
                for try await event in session.events {
                    guard !finished else { throw CapabilityError.invalidRequest("Event after Decision completion") }
                    switch event {
                    case .text(let value):
                        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw CapabilityError.invalidRequest("Decision returned text instead of a tool")
                        }
                    case .toolCall(let call):
                        let data = Data(call.argumentsJSON.utf8)
                        guard result == nil, call.name == name,
                            let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
                            object.count == 1, let action = object["action"].flatMap(InputDisposition.init(rawValue:)),
                            prompt.choices.contains(action)
                        else { throw CapabilityError.invalidRequest("Invalid classification tool call") }
                        result = action
                    case .finished(.toolCalls): finished = true
                    case .finished: throw CapabilityError.invalidRequest("Incomplete Decision tool response")
                    case .usage: break
                    }
                }
                guard finished, let result else {
                    throw CapabilityError.invalidRequest("Missing classification tool call")
                }
                return result
            }
        }
    }

    private enum Text {
        static func classify(
            _ prompt: InputDecisionSnapshot.Prompt, model: any ChatCapability, record: @Sendable (String) -> Void
        ) async throws -> InputDisposition {
            // Gemma's text adapter removes system messages. Keep this instruction in the submitted user message.
            let instruction = try AgentPrompts.text(
                "Assistant/InputDecision",
                prompt.choices.contains(.continueListening) ? "textSpeechOutput" : "textOutput")
            let content = prompt.text + "\n" + instruction
            let request = try ChatRequest(
                messages: [.init(role: .user, content: content)], context: prompt.context,
                maximumOutputTokens: 16, temperature: 0)
            record("Text\n\nuser\n" + content + "\n\nmaximum_output_tokens: 16")
            let session = try await model.chat(request)
            return try await session.withCleanup {
                var output = ""
                var finished = false
                for try await event in session.events {
                    guard !finished else { throw CapabilityError.invalidRequest("Event after Decision completion") }
                    switch event {
                    case .text(let value):
                        output += value
                        guard output.utf8.count <= 64 else {
                            throw CapabilityError.invalidRequest("Decision returned extra text")
                        }
                    case .finished(.stop): finished = true
                    case .finished, .toolCall: throw CapabilityError.invalidRequest("Invalid text Decision response")
                    case .usage: break
                    }
                }
                guard finished else { throw CapabilityError.invalidRequest("Missing text Decision completion") }
                return try label(output.trimmingCharacters(in: .whitespacesAndNewlines), in: prompt)
            }
        }
    }
}
