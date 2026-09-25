/// An explicitly registered action address, never a reflection or executable source path.
public struct ActionPath: Hashable, Sendable, CustomStringConvertible {
    public let module: String
    public let function: String

    public init(module: String, function: String) {
        self.module = module
        self.function = function
    }

    public var description: String { "\(module).\(function)" }
}
