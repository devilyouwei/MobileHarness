import AgentCore

/// Classifies the current AgentCore output without executing side effects.
enum ExecutionRouter {
    enum Route {
        case action(ActionCall)
        case tool(ToolCall)
        case finish
        case cancel
        case observe
    }

    static func route(_ output: AgentOutput) throws -> Route {
        switch output {
        case .actionCall(let token): .action(token)
        case .toolCall(let call): .tool(call)
        case .control("assistant.finished"): .finish
        case .control(let state) where state.hasPrefix("assistant.error:"): .cancel
        case .control: .observe
        }
    }
}
