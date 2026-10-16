import Foundation

/// Opaque UI ownership; presentation never interprets business transport types.
public struct PresentationOwner: Sendable, Equatable {
    public let source: String
    public let session: String
    public init(source: String, session: String) {
        self.source = source
        self.session = session
    }
}

@MainActor public protocol ExecutionFailureReporting: AnyObject, Sendable {
    func recordFailure(
        title: String, source: String, message: String, failureCode: String?, context: ExecutionIssue.Context?)
}

public protocol ProviderRequestFailure: Error {
    var failureCode: String? { get }
}
