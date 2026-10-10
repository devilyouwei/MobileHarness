import Foundation

/// No model knowledge; feedback does not queue behind the work awaiting it.
public struct AgentRoundCoordinator: Sendable {
    public struct Call: Sendable {
        public let id: UUID
        public let policy: GenerationFeedbackPolicy
        public var terminal: Bool
    }
    public let id: UUID
    public let taskID: UUID
    private var calls: [Call] = []
    private var sealed = false
    private var cancelled = false
    public var complete: Bool { !cancelled && sealed && calls.allSatisfy(\.terminal) }
    public var needsObservation: Bool { complete && calls.contains { $0.policy == .observation } }
    public init(id: UUID = UUID(), taskID: UUID) {
        self.id = id
        self.taskID = taskID
    }
    public mutating func register(id: UUID, policy: GenerationFeedbackPolicy) throws {
        guard !cancelled, !sealed, calls.count < 120, !calls.contains(where: { $0.id == id }) else {
            throw CommunicationError.invalidPayload
        }
        calls.append(Call(id: id, policy: policy, terminal: false))
    }
    public mutating func accept(callID: UUID, roundID: UUID) throws {
        guard !cancelled, roundID == id, let index = calls.firstIndex(where: { $0.id == callID }),
            !calls[index].terminal
        else {
            throw CommunicationError.unauthorized
        }
        calls[index].terminal = true
    }
    public mutating func cancel() { cancelled = true }
    public mutating func seal() throws {
        guard !sealed else { throw CommunicationError.outOfOrder }
        sealed = true
    }
}
