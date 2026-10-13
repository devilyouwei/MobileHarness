import Foundation

public struct ToolResult: Codable, Equatable, Sendable {
    public let roundID: UUID?
    public let completion: AgentActionCompletion?
    public let callID: UUID
    public let value: String
    public let isError: Bool
    public let failureCode: String?
    public var isCancellationOnly: Bool {
        guard failureCode == nil || failureCode == "cancelled" else { return false }
        if case .report(let report) = completion { return report.isCancellationOnly }
        return failureCode == "cancelled"
    }
    public var hasFailure: Bool {
        if isCancellationOnly { return false }
        if isError || failureCode != nil { return true }
        if case .report(let report) = completion { return report.hasFailures }
        return false
    }
    public var requiresReasoning: Bool {
        if isCancellationOnly { return false }
        if hasFailure { return true }
        // Legacy native results carry their explicit value without a canonical completion case.
        return completion?.hasBusinessOutput ?? true
    }
    public init(
        callID: UUID, value: String, isError: Bool = false, failureCode: String? = nil,
        completion: AgentActionCompletion? = nil, roundID: UUID? = nil
    ) {
        self.roundID = roundID
        self.completion = completion
        self.callID = callID
        self.value = value
        self.isError = isError
        precondition(failureCode.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
        self.failureCode = failureCode
    }
}
