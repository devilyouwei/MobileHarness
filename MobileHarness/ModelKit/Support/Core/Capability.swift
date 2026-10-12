import Foundation

/// Unavailability reasons are technical diagnostics; consumers own localized presentation.
public enum CapabilityAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// No provider, model, backend, or business identity is part of the consumer contract.
public protocol Capability: Sendable {
    var availability: CapabilityAvailability { get async }
}

/// Typed capability failures with diagnostic details, not user-facing copy or recovery instructions.
public enum CapabilityError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(String)
    case unavailable(String)
    case bufferOverflow
    case eventTooLarge
    case sessionClosed
    case multipleConsumers
    case inputFinished
    case inputBusy

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason), .unavailable(let reason): reason
        case .bufferOverflow: "Model stream buffer capacity exceeded (bufferOverflow)"
        case .eventTooLarge: "Model output exceeds the event size limit (eventTooLarge)"
        case .sessionClosed: "Model session is closed (sessionClosed)"
        case .multipleConsumers: "Model stream already has a consumer (multipleConsumers)"
        case .inputFinished: "Model input is already finished (inputFinished)"
        case .inputBusy: "Model is processing another request (inputBusy)"
        }
    }
}

/// Opaque request and owner scope correlation; callers own all business meaning.
public struct InferenceContext: Equatable, Sendable {
    public let requestID: UUID
    public let scopeID: UUID

    public init(requestID: UUID = UUID(), scopeID: UUID = UUID()) {
        self.requestID = requestID
        self.scopeID = scopeID
    }
}
