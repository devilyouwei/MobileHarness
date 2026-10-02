import ActionRuntime
import Actions
import ToolRuntime
import Tools

/// Pure behavior assembly. Device creation and runtime lifetime stay with the host.
public struct BehaviorAssembly: Sendable {
    public let actions: ActionRegistry
    public let tools: ToolRegistry
    public let toolPaths: Set<String>

    public init(
        presentation: any UIPresentationCapability & UIUpdateCapability,
        playback: any SpeechPlaybackCapability,
        pose: any PosePresentationCapability,
        camera: any CameraControlCapability,
        gesture: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void,
        shakeBase: @escaping @Sendable (Int, ActionInvocation) async throws -> Void
    ) throws {
        try self.init(
            actionModules: ActionModules.builtIn(
                presentation: presentation, playback: playback, gesture: gesture, shakeBase: shakeBase),
            toolModules: ToolModules.builtIn(presentation: pose, updates: presentation, camera: camera))
    }

    /// Explicit catalog injection for isolated tests or other hosts; never runtime discovery.
    public init(
        actionModules: [any ActionModule], toolModules: [any ToolModule]
    ) throws {
        let actions = try ActionRegistry(modules: actionModules)
        let tools = try ToolRegistry(modules: toolModules)
        self.actions = actions
        self.tools = tools
        toolPaths = Set(toolModules.flatMap { $0.definitions.map(\.path) })
    }
}
