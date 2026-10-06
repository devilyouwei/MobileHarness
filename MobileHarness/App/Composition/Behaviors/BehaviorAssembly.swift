import ActionRuntime
import Actions

/// Pure behavior assembly. Device creation and runtime lifetime stay with the host.
public struct BehaviorAssembly: Sendable {
    public let actions: ActionRegistry
    public let tools: ToolRegistry
    public let toolPaths: Set<String>

    public init(
        presentation: any UIPresentationCapability & UIUpdateCapability,
        playback: any SpeechPlaybackCapability,
        pose: any PosePresentationCapability,
        historyPresentation: any HistoryPresentationCapability, camera: any CameraControlCapability,
        history: any HistoryQueryCapability, historyMutations: any HistoryMutationCapability,
        gesture: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void,
        shakeBase: @escaping @Sendable (Int, ActionInvocation) async throws -> Void,
        aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void
    ) throws {
        let modules = CapabilityModules.builtIn(
            presentation: presentation, playback: playback, pose: pose,
            historyPresentation: historyPresentation, camera: camera,
            history: history, historyMutations: historyMutations, gesture: gesture, shakeBase: shakeBase, aim: aim)
        try self.init(capabilityModules: modules)
    }

    public init(capabilityModules: [any CapabilityModule]) throws {
        let catalog = try CapabilityCatalog(modules: capabilityModules)
        try self.init(actionModules: [catalog.actions], toolModules: [catalog.tools])
    }

    /// Explicit catalog injection for isolated tests or other hosts; never runtime discovery.
    public init(
        actionModules: [any ActionModule], toolModules: [any ToolModule]
    ) throws {
        let actions = try ActionRegistry(modules: actionModules)
        let tools = try ToolRegistry(modules: toolModules)
        self.actions = actions
        self.tools = tools
        toolPaths = Set(toolModules.flatMap { $0.definitions.map { $0.path.description } })
    }
}
