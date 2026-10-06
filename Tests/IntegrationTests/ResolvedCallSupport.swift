import AgentCore
import Foundation

func expectedActionCall(name: String, parameters: [String: String] = [:]) -> ActionCall {
    let module = name == "say" ? "Speech" : "UI"
    return ActionCall(
        actionPath: ActionPath(
            domain: module, module: name == "say" ? "Playback" : "Expression", function: name == "say" ? "speak" : name),
        channel: name == "say" ? "Speech" : "Display", parameters: parameters)
}

let fixtureToolID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
func expectedPrint(_ text: String) -> AgentOutput {
    .toolCall(ToolCall(id: fixtureToolID, toolPath: "UI.Caption.print", arguments: ["text": text]))
}
func normalizeToolID(_ output: AgentOutput) -> AgentOutput {
    guard case .toolCall(let call) = output else { return output }
    return .toolCall(ToolCall(id: fixtureToolID, toolPath: call.toolPath, arguments: call.arguments))
}
func normalizeToolIDs(_ events: [GenerationEvent]) -> [GenerationEvent] {
    events.map {
        guard case .tool(let call) = $0 else { return $0 }
        return .tool(ToolCall(id: fixtureToolID, toolPath: call.toolPath, arguments: call.arguments))
    }
}
