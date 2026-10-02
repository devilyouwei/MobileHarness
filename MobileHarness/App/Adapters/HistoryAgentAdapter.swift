import AgentCore
import Agents
import Foundation
import StorageChat

enum HistoryAgentAdapter {
    static func preview(_ turn: ConversationRecord) -> String {
        do {
            let configuration = try AgentConfigurations.load(named: "Assistant")
            var trace = try GenerationTrace(
                capabilities: AssistantAgent.runtimeCapabilities(configuration.capabilities),
                textMapping: AssistantAgent.mapText)
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
                case .tool(let call): return prefix + "[Tool] \(call.toolPath) \(call.arguments)"
                case .action(let call): return prefix + "[\(call.channel)] \(call.actionPath) \(call.parameters)"
                }
            }
            return ([trace.parserError ?? "已接收内容的解析结果；不代表实际执行顺序。"] + lines).joined(separator: "\n")
        } catch { return "预览失败：\(error)" }
    }
}
