/// Passive runtime facts of one execution facility. The owning container projects them into its State tree.
public struct ExecutionRuntimeFacts: Sendable {
    public enum Value: Sendable, Equatable {
        case count(Int)
        case flag(Bool)
    }
    public let path: String
    public let runtime: [String: Value]
    public let cleanupFailed: Bool
    public init(path: String, runtime: [String: Value], cleanupFailed: Bool = false) {
        self.path = path
        self.runtime = runtime
        self.cleanupFailed = cleanupFailed
    }
}
