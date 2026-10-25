import Foundation

/// Transport-bound endpoint incarnation and session. Carries no role or permission semantics.
public struct ExecutionOwner: Codable, Hashable, Sendable {
    public let endpoint: String
    public let incarnation: String
    public let sessionID: String
    public init(endpoint: String, incarnation: String, sessionID: String) {
        self.endpoint = endpoint
        self.incarnation = incarnation
        self.sessionID = sessionID
    }
}
public enum ActionFeedback: Sendable { case none, failuresOnly, terminal }
public enum ActionResultDelivery: Sendable { case accepted, retry, closed }
public enum ActionHostError: Error, Sendable {
    case outOfOrder, unavailable, scopeClosed, unauthorized, unsupportedContract, staleIncarnation, invalidPayload
}
