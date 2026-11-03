import FunctionContracts

public enum WebActions {}

public protocol WebCapability: Sendable {
    func perform(_ operation: String, invocation: any FunctionInput) async throws -> String
}
