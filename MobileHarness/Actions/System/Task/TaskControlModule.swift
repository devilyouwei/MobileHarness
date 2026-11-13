import FunctionContracts

/// Model and fixed host callers share these finite, protocol-neutral functions.
@ActionCatalog
public struct TaskControlModule: CapabilityModule {
    private let capability: any TaskControlCapability
    public init(capability: any TaskControlCapability) { self.capability = capability }
    public var definitions: [ActionFunction] {
        [
            SystemActions.sendMessageDefinition(completing: {
                try await SystemActions.sendMessage($0, capability: capability)
            }),
            SystemActions.loadSkillsDefinition(completing: {
                try await SystemActions.loadSkills($0, capability: capability)
            }),
            SystemActions.releaseSkillsDefinition(completing: {
                try await SystemActions.releaseSkills($0, capability: capability)
            }),
            SystemActions.startTaskDefinition(completing: {
                try await SystemActions.startTask($0, capability: capability)
            }
            ),
            SystemActions.finishTaskDefinition(completing: {
                try await SystemActions.finishTask($0, capability: capability)
            }),
        ]
    }
}
