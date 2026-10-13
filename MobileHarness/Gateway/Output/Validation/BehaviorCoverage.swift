import AgentCore
import CallRuntime
import ExecutionRuntime
import FunctionContracts

/// Startup permission coverage, separate from behavior construction and effect execution.
public enum BehaviorCoverage {
    public static func validate(
        actions: ActionRegistry, toolPaths: Set<String>, capabilities: [CapabilityRegistry]
    ) throws {
        guard capabilities.count <= 128 else { throw HarnessError.queueFull }
        for capability in capabilities {
            for action in capability.actions.map(\.path) + capability.internalActions.map(\.path) {
                if action.description == "Agent.Communication.send" { continue }
                _ = try actions.definition(
                    for: ActionIdentifier(domain: action.domain, module: action.module, function: action.function))
            }
            for path in capability.tools.map(\.path) + capability.internalTools.map(\.path) {
                guard toolPaths.contains(path) else { throw ToolRegistrationError.missingHandler(path) }
            }
        }
    }
}
