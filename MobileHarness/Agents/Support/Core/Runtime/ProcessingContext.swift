import Foundation

/// Local processing identity. It grants neither messaging nor execution authority.
/// Runtime consumers bind authority independently to the registered Agent instance.
public struct ProcessingContext: Sendable {
    @TaskLocal public static var current: ProcessingContext?
    public let provenance: InputMetadata?
    public let requestID: String
    public let sessionID: String
    public let generation: String
    public let source: String
    public let sequence: UInt64
    public let parentID: String?
    public let rootID: String
    public let hops: Int
    public let deadline: ContinuousClock.Instant?
    public let turn: AgentTurn?
    public init(
        requestID: String? = nil, sessionID: String, generation: String? = nil,
        source: String = "user", sequence: UInt64 = 0, rootID: String? = nil,
        parentID: String? = nil, hops: Int = 0, deadline: ContinuousClock.Instant? = nil, turn: AgentTurn? = nil,
        provenance: InputMetadata? = nil
    ) {
        let requestID = requestID ?? UUID().uuidString
        self.provenance = provenance
        self.requestID = requestID
        self.sessionID = sessionID
        self.generation = generation ?? Self.current?.generation ?? sessionID
        self.source = source
        self.sequence = sequence
        self.rootID = rootID ?? requestID
        self.parentID = parentID
        self.hops = hops
        self.deadline = deadline
        self.turn = turn
    }
    public func validate() throws {
        guard [requestID, sessionID, generation, source, rootID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
            parentID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true, (0...8).contains(hops)
        else { throw CommunicationError.invalidPayload }
        guard deadline.map({ ContinuousClock.now < $0 }) ?? true else { throw CommunicationError.expired }
    }
    /// A private processing value, not a Signal to be routed through InputGateway.
    public func input(_ payload: InputPayload) -> AgentInput {
        AgentInput(
            id: requestID, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: source, origin: .local, sequence: sequence, rootID: rootID,
                parentID: parentID, hops: hops, deadline: deadline, generation: generation), turn: turn)
    }
}

extension AgentInput {
    public var context: ProcessingContext {
        ProcessingContext(
            requestID: id, sessionID: sessionID, generation: metadata.generation,
            source: metadata.source, sequence: metadata.sequence, rootID: metadata.rootID,
            parentID: metadata.parentID, hops: metadata.hops, deadline: metadata.deadline, turn: turn,
            provenance: metadata)
    }
    public func validate(_ message: AgentMessage) throws {
        if metadata.origin == .local {
            try context.validate()
            try message.validate()
        } else {
            _ = try message.validatedSize()
        }
    }
}
