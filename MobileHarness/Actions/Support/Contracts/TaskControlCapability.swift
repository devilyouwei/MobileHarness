import Foundation

/// Neutral host endpoint; functions cannot infer or fabricate Agent authorization.
public protocol TaskControlCapability: Sendable {
    func controlTask(_ operation: String, arguments: [String: String], invocation: any FunctionInput) async throws
        -> String
}

@MainActor public protocol TaskControlBinding: AnyObject, Sendable {
    var handler: (@Sendable (String, [String: String], String, String, String, String?) async throws -> String)? {
        get set
    }
}
