import Foundation

public enum CapabilityAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// No provider, model, backend, or business identity is part of the consumer contract.
public protocol Capability: Sendable {
    var availability: CapabilityAvailability { get async }
}

public enum CapabilityError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case unavailable(String)
    case bufferOverflow
    case eventTooLarge
    case sessionClosed
    case multipleConsumers
    case inputFinished
    case inputBusy
}

public struct InferenceContext: Equatable, Sendable {
    public let requestID: UUID
    public let conversationID: UUID

    public init(requestID: UUID = UUID(), conversationID: UUID = UUID()) {
        self.requestID = requestID
        self.conversationID = conversationID
    }
}
