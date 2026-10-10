import Foundation

/// Output representation is encoded once and retains its validated immutable domain message.
public struct CommunicationAction: Sendable, Equatable {
    public let id: UUID
    public let message: AgentMessage
    public let target: AgentID?
    private let content: Data
    public init(id: UUID = UUID(), message: AgentMessage, target: AgentID? = nil) throws {
        self.id = id
        self.message = message
        self.target = target
        content = try message.encodedContent()
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.target == rhs.target && lhs.message.contract == rhs.message.contract
            && lhs.content == rhs.content
    }
}

public struct CommunicationReceipt: Codable, Sendable {
    public let callID: UUID
    public let report: DeliveryReport
    public let owner: ExecutionOwner
    public let causality: SignalCausality
    public init(callID: UUID, report: DeliveryReport, owner: ExecutionOwner, causality: SignalCausality) {
        self.callID = callID
        self.report = report
        self.owner = owner
        self.causality = causality
    }
}

/// Agent-owned bounded waiters. Runtime receipts bypass the model inbox.
public actor CommunicationReceipts {
    private var waiting: [UUID: CheckedContinuation<DeliveryReport, any Error>] = [:]
    private var early: [UUID: Result<DeliveryReport, any Error>] = [:]
    private var registered: Set<UUID> = []
    private var recording: Set<UUID> = []
    public init() {}
    public func register(_ id: UUID) throws {
        guard registered.count + early.count < 16, early[id] == nil, registered.insert(id).inserted else {
            throw CommunicationError.capacityExceeded
        }
    }
    public func accept(
        _ receipt: CommunicationReceipt,
        record: @Sendable () async throws -> Void = {}
    ) async throws {
        guard registered.contains(receipt.callID), recording.insert(receipt.callID).inserted else {
            throw CommunicationError.unauthorized
        }
        defer { recording.remove(receipt.callID) }
        do { try await record() } catch {
            if registered.remove(receipt.callID) != nil {
                if let continuation = waiting.removeValue(forKey: receipt.callID) {
                    continuation.resume(throwing: error)
                } else {
                    early[receipt.callID] = .failure(error)
                }
            }
            throw error
        }
        guard registered.remove(receipt.callID) != nil else { throw CommunicationError.scopeClosed }
        if let continuation = waiting.removeValue(forKey: receipt.callID) {
            continuation.resume(returning: receipt.report)
        } else {
            early[receipt.callID] = .success(receipt.report)
        }
    }
    public func wait(_ id: UUID) async throws -> DeliveryReport {
        if let value = early.removeValue(forKey: id) { return try value.get() }
        try Task.checkCancellation()
        guard registered.contains(id), waiting[id] == nil else { throw CommunicationError.scopeClosed }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    public func cancel(_ id: UUID) {
        registered.remove(id)
        early[id] = nil
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    public func close() {
        for id in Array(registered) { cancel(id) }
        early.removeAll()
    }
}
