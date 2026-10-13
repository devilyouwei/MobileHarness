import Foundation

/// No model knowledge; feedback does not queue behind the work awaiting it.
public struct AgentRoundCoordinator: Sendable {
    public struct Call: Sendable {
        public let id: UUID
        public var result: ToolResult?
        public var terminal: Bool { result != nil }
    }
    public let id: UUID
    public let taskID: UUID
    private var calls: [Call] = []
    private var sealed = false
    private var cancelled = false
    public var complete: Bool { !cancelled && sealed && calls.allSatisfy(\.terminal) }
    public var needsReasoning: Bool { complete && calls.contains { $0.result?.requiresReasoning == true } }
    public init(id: UUID = UUID(), taskID: UUID) {
        self.id = id
        self.taskID = taskID
    }
    public mutating func register(id: UUID) throws {
        guard !cancelled, !sealed, calls.count < 120, !calls.contains(where: { $0.id == id }) else {
            throw CommunicationError.invalidPayload
        }
        calls.append(Call(id: id))
    }
    public mutating func accept(_ result: ToolResult, roundID: UUID) throws {
        guard !cancelled, roundID == id, result.roundID == nil || result.roundID == id,
            result.value.utf8.count <= 65_536, let index = calls.firstIndex(where: { $0.id == result.callID }),
            !calls[index].terminal
        else {
            throw CommunicationError.unauthorized
        }
        calls[index].result = result
    }
    public mutating func cancel() { cancelled = true }
    public mutating func seal() throws {
        guard !sealed else { throw CommunicationError.outOfOrder }
        sealed = true
    }
}
