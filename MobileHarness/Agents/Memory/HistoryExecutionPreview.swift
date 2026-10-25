import AgentCore
import Foundation
import FunctionContracts
import PlatformKit
import UI

enum HistoryExecutionPreview {
    static func preview(_ turn: HistoryTurn) -> String {
        do {
            guard let snapshot = turn.decisionMetadata else {
                throw GenerationError.invalidParameters
            }
            struct Catalog: Decodable {
                struct Action: Decodable {
                    let path: String
                    let alias: String
                    let channel: String
                    let required: [String]
                    let optional: [String]
                }
                struct Tool: Decodable {
                    let definitionJSON: String?
                    let path: String
                    let alias: String
                    let required: [String]
                    let optional: [String]
                }
                let actions: [Action]
                let tools: [Tool]
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(snapshot.catalogJSON.utf8))
            let modelCapabilities = try CapabilityRegistry(
                actions: catalog.actions.map {
                    let parts = $0.path.split(separator: ".").map(String.init)
                    guard parts.count == 3 else { throw GenerationError.invalidParameters }
                    return ActionRegistration(
                        alias: $0.alias, path: .init(domain: parts[0], module: parts[1], function: parts[2]),
                        defaultChannel: $0.channel, requiredParameters: Set($0.required),
                        optionalParameters: Set($0.optional))
                },
                tools: try catalog.tools.map {
                    ToolRegistration(
                        alias: $0.alias, path: $0.path,
                        requiredParameters: Set($0.required), optionalParameters: Set($0.optional),
                        definition: try $0.definitionJSON.flatMap {
                            $0.isEmpty ? nil : try JSONDecoder().decode(NativeToolDefinition.self, from: Data($0.utf8))
                        })
                }, channels: ["Speech", "Display"])
            var trace = GenerationTrace(
                capabilities: modelCapabilities,
                textMapping: AssistantAgent.mapText, segmentation: try AssistantAgent.textSegmentation)
            try trace.append(turn.response)
            if turn.finishReason != nil { trace.finish() }
            var depth = 0
            let lines = trace.events.enumerated().map { index, event in
                if case .scheduling(.endWait) = event { depth = max(0, depth - 1) }
                let prefix = "\(index + 1). " + String(repeating: "  ", count: depth)
                switch event {
                case .scheduling(.beginWait):
                    depth += 1
                    return prefix + "<wait>"
                case .scheduling(.endWait): return prefix + "</wait>"
                case .rejected(let rejection): return prefix + "[Rejected] \(rejection.alias): \(rejection.reason)"
                case .tool(let call): return prefix + "[Tool] \(call.toolPath) \(call.arguments)"
                case .action(let call): return prefix + "[\(call.channel)] \(call.actionPath) \(call.parameters)"
                }
            }
            return ([trace.parserError ?? "已接收内容的解析结果；不代表实际执行顺序。"] + lines).joined(separator: "\n")
        } catch { return "预览失败：\(error)" }
    }
}
