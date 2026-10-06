import ActionRuntime

/// Partial catalog projections for existing isolated hosts; definition lists belong to NexArmModule.
public struct NexArmGestureActionModule: ActionModule {
    private let perform: @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void
    public init(perform: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void) {
        self.perform = perform
    }
    public var definitions: [ActionDefinition] { NexArmModule.gestureDefinitions(perform: perform) }
}
public struct NexArmBaseActionModule: ActionModule {
    private let move: @Sendable (Int, ActionInvocation) async throws -> Void
    public init(move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void) { self.move = move }
    public var definitions: [ActionDefinition] { NexArmModule.baseDefinitions(move: move) }
}

public struct NexArmTrackingToolModule: ToolModule {
    private let aim: @Sendable (Double, Double, ToolInvocation) async throws -> Void
    public init(aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void) { self.aim = aim }
    public var definitions: [ToolDefinition] { NexArmModule.trackingDefinitions(aim: aim) }
}
