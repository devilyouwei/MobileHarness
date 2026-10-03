import AgentCore

/// Classifies the current AgentCore output without executing side effects.
enum ExecutionRouter {
    enum Route {
        case action(ActionCall)
        case tool(ToolCall)
        case scheduling(SchedulingDirective)
        case finish
        case cancel
        case observe
    }

    static func route(_ output: AgentOutput) throws -> Route {
        switch output {
        case .rejectedCall(let rejection): throw rejection
        case .actionCall(let token): .action(token)
        case .scheduling(let directive): .scheduling(directive)
        case .toolCall(let call): .tool(call)
        case .control("assistant.finished"), .control("agent.finished"): .finish
        case .control(let state) where state.hasPrefix("assistant.error:") || state.hasPrefix("agent.error:"): .cancel
        case .control: .observe
        }
    }
}
