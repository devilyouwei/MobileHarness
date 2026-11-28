import AgentCore
import Foundation

/// Static implementation registrations are validated before on-demand role instances or models are started.
public struct AgentRequestImplementation: Sendable {
    public let protocolID: String
    public let operations: Set<AgentRequestOperation>
    public let acceptsTextSubmission: Bool
    let handle: @Sendable (any Agent, AgentProtocolRequest) async throws -> AgentRequestReply
    public init<Role: Agent>(
        protocolID: String, role: Role.Type, operations: Set<AgentRequestOperation>,
        acceptsTextSubmission: Bool = false,
        handler: @escaping @Sendable (Role, AgentProtocolRequest) async throws -> AgentRequestReply
    ) {
        self.protocolID = protocolID
        self.operations = operations
        self.acceptsTextSubmission = acceptsTextSubmission
        handle = { agent, request in
            guard let role = agent as? Role else { throw CommunicationError.invalidPayload }
            return try await handler(role, request)
        }
    }
}

/// Code-owned event adapters. Declarations select a subset of implemented variants.
public struct AgentEventImplementation: Sendable {
    public let protocolID: String
    public let variants: Set<String>
    let handle: @Sendable (any Agent, AgentInput) async throws -> Void
    public init<Role: Agent>(
        protocolID: String, variants: Set<String> = [], role: Role.Type,
        handler: @escaping @Sendable (Role, AgentInput) async throws -> Void
    ) {
        self.protocolID = protocolID
        self.variants = variants
        handle = { agent, input in
            guard let role = agent as? Role else { throw CommunicationError.invalidPayload }
            try await handler(role, input)
        }
    }
}
