import Actions
import AgentCore
import Tools

/// Pure behavior assembly. Device creation and runtime lifetime stay with the host.
public struct BehaviorAssembly: Sendable {
    public let actions: ActionRegistry
    public let tools: ToolRegistry

    public init(
        presentation: any UIPresentationCapability & UIUpdateCapability,
        playback: any SpeechPlaybackCapability,
        pose: any PosePresentationCapability,
        gesture: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void,
        shakeBase: @escaping @Sendable (Int, ActionInvocation) async throws -> Void,
        capabilities: [CapabilityRegistry]
    ) throws {
        try self.init(
            actionModules: ActionModules.builtIn(
                presentation: presentation, playback: playback, gesture: gesture, shakeBase: shakeBase),
            toolModules: ToolModules.builtIn(presentation: pose, updates: presentation), capabilities: capabilities)
    }

    /// Explicit catalog injection for isolated tests or other hosts; never runtime discovery.
    public init(
        actionModules: [any ActionModule], toolModules: [any ToolModule], capabilities: [CapabilityRegistry]
    ) throws {
        guard capabilities.count <= 128 else { throw HarnessError.queueFull }
        let actions = try ActionRegistry(modules: actionModules)
        for capability in capabilities {
            for action in capability.actions.map(\.path) + capability.internalActions.map(\.path) {
                _ = try actions.definition(for: .init(module: action.module, function: action.function))
            }
        }
        let tools = try ToolRegistry(modules: toolModules)
        let paths = Set(toolModules.flatMap { $0.definitions.map(\.path) })
        for capability in capabilities {
            for path in capability.tools.map(\.path) + capability.internalTools.map(\.path) {
                guard paths.contains(path) else { throw ToolRegistrationError.missingHandler(path) }
            }
        }
        self.actions = actions
        self.tools = tools
    }
}
