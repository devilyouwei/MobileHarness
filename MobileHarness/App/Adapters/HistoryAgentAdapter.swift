import AgentCore
import Agents
import Foundation
import UI

enum HistoryAgentAdapter {
    static func preview(_ turn: HistoryTurn) -> String { preview(turn, agent: "assistant") }

    static func preview(_ turn: HistoryTurn, agent: String) -> String {
        do {
            let name: String
            switch agent {
            case "assistant": name = "Assistant"
            case "photographer": name = "Photographer"
            case "memory": name = "Memory"
            case "applicationControl": name = "ApplicationControl"
            default: throw HarnessError.unknownAgent
            }
            let configuration = try AgentConfigurations.load(named: name)
            let capabilities: CapabilityRegistry
            switch agent {
            case "photographer":
                capabilities = try PhotographerContextState.runtimeCapabilities(configuration.capabilities)
            case "memory": capabilities = try MemoryContextState.runtimeCapabilities(configuration.capabilities)
            case "applicationControl":
                capabilities = try ApplicationControlContextState.runtimeCapabilities(configuration.capabilities)
            default: capabilities = try AssistantAgent.runtimeCapabilities(configuration.capabilities)
            }
            let modelCapabilities = try AgentCommunicationAdapter.catalog(
                capabilities, policy: configuration.communication)
            var trace = try GenerationTrace(
                capabilities: modelCapabilities,
                textMapping: AssistantAgent.mapText, segmentation: try AssistantAgent.textSegmentation)
            for delta in turn.fragments { try trace.append(delta) }
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
