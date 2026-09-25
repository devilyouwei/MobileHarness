import AgentCore

func expectedActionCall(name: String, parameters: [String: String] = [:]) -> ActionCall {
    let module = name == "say" ? "Speech" : "UI"
    return ActionCall(
        actionPath: ActionPath(module: module, function: name == "say" ? "speak" : name),
        channel: name == "say" ? "Speech" : "Display", parameters: parameters)
}
