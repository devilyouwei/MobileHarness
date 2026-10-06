import FunctionContracts

/// Partial catalog projections for existing isolated hosts; definition lists belong to NexArmModule.
public struct NexArmGestureModule: CapabilityModule {
    private let perform: @Sendable (NexArmActions.GestureRequest, any FunctionInput) async throws -> Void
    public init(perform: @escaping @Sendable (NexArmActions.GestureRequest, any FunctionInput) async throws -> Void) {
        self.perform = perform
    }
    public var definitions: [ActionFunction] { NexArmModule.gestureDefinitions(perform: perform) }
}
public struct NexArmBaseModule: CapabilityModule {
    private let move: @Sendable (Int, any FunctionInput) async throws -> Void
    public init(move: @escaping @Sendable (Int, any FunctionInput) async throws -> Void) { self.move = move }
    public var definitions: [ActionFunction] { NexArmModule.baseDefinitions(move: move) }
}

public struct NexArmTrackingModule: CapabilityModule {
    private let aim: @Sendable (Double, Double, any FunctionInput) async throws -> Void
    public init(aim: @escaping @Sendable (Double, Double, any FunctionInput) async throws -> Void) { self.aim = aim }
    public var definitions: [ActionFunction] { NexArmModule.trackingDefinitions(aim: aim) }
}
