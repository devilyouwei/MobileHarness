import AgentCore
import FunctionContracts

/// Startup permission coverage, separate from behavior construction and effect execution.
public enum BehaviorCoverage {
    public static func validate(
        catalog: ActionCatalogSnapshot, capabilities: [CapabilityRegistry]
    ) throws {
        guard capabilities.count <= 128 else { throw HarnessError.queueFull }
        for capability in capabilities {
            for action in capability.actions.map(\.path) + capability.internalActions.map(\.path) {
                if action.description == "Agent.Communication.send" { continue }
                guard
                    catalog.entries.contains(where: {
                        $0.path.description == action.description && $0.protocols.contains(.action)
                    })
                else { throw HarnessError.forbiddenFunction }
            }
            for path in capability.tools.map(\.path) + capability.internalTools.map(\.path) {
                if WriterLocalTools.contains(path) { continue }
                guard catalog.entries.contains(where: { $0.path.description == path && $0.protocols.contains(.tool) })
                else { throw HarnessError.forbiddenTool }
            }
        }
    }
}
