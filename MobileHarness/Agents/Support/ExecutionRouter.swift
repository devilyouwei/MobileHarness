import AgentCore
import FunctionContracts

/// Classifies the current AgentCore output without executing side effects.
enum ExecutionRouter {
    enum Route {
        case communication(CommunicationAction)
        case roundBranchSealed(CallLane, String)
        case roundStarted
        case roundFinished
        case action(ActionCall)
        case actionControl(ActionControl)
        case tool(ToolCall)
        case finish
        case cancel
        case observe
    }

    static func route(_ output: AgentOutput) throws -> Route {
        switch output {
        case .communication(let call): .communication(call)
        case .rejectedCall(let rejection): throw rejection
        case .roundBranchSealed(let lane, let id): .roundBranchSealed(lane, id)
        case .roundStarted: .roundStarted
        case .roundFinished: .roundFinished
        case .actionCall(let token): .action(token)
        case .actionControl(let control): .actionControl(control)
        case .toolCall(let call): .tool(call)
        case .control("assistant.finished"), .control("agent.finished"): .finish
        case .control("agent.cancelled"): .cancel
        case .control(let state) where state.hasPrefix("assistant.error:") || state.hasPrefix("agent.error:"): .cancel
        case .control(let state)
        where state.hasPrefix("assistant.historyError:") || state.hasPrefix("agent.historyError:"):
            throw OutputRecordingError(description: state)
        case .control: .observe
        }
    }
}

private struct OutputRecordingError: Error, CustomStringConvertible {
    let description: String
}

public enum OutputValidator {
    public static func validate(_ output: AgentOutput, descriptor: AgentDescriptor) throws {
        guard descriptor.outputs.contains(output.kind) else { throw HarnessError.forbiddenOutput }
        switch output {
        case .actionCall(let token):
            guard (token.isWait && descriptor.capabilities.supportsWait) || descriptor.capabilities.permits(token)
            else { throw HarnessError.forbiddenFunction }
        case .toolCall(let call):
            guard descriptor.capabilities.permits(call) else { throw HarnessError.forbiddenTool }
        default: break
        }
    }
}
