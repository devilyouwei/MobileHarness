import AgentCore

public enum OutputValidator {
    public static func validate(_ output: AgentOutput, descriptor: AgentDescriptor) throws {
        guard descriptor.outputs.contains(output.kind) else { throw HarnessError.forbiddenOutput }
        switch output {
        case .actionCall(let token):
            guard descriptor.capabilities.permits(token) else { throw HarnessError.forbiddenFunction }
        case .toolCall(let call):
            guard descriptor.capabilities.permits(call) else { throw HarnessError.forbiddenTool }
        default: break
        }
    }
}
