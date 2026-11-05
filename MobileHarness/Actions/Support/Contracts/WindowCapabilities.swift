import Foundation

public enum WindowOperation: String, Sendable { case focus, minimize, maximize, restore, move, close }
public protocol WindowControlCapability: Sendable {
    func performWindow(_ operation: WindowOperation, id: String, x: Double?, y: Double?, invocation: any FunctionInput)
        async throws
}
