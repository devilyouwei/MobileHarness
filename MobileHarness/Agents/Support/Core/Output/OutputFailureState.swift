import Foundation
import FunctionContracts

/// Output failure observation, distinct from scheduled Action execution and Agent-facing results.
public struct OutputFailureRecord: Identifiable, Sendable, Equatable {
    public let diagnostic: AgentFailureDiagnostic?
    public let sessionID: String?
    public let roundID: String?
    public let inputID: String?
    public let id: String
    public let source: AgentID
    public let title: String
    public let message: String
    public let failureCode: String?
    public let time: Date
    public init(
        id: String = UUID().uuidString, source: AgentID, title: String, message: String, time: Date = Date(),
        failureCode: String? = nil, inputID: String? = nil, diagnostic: AgentFailureDiagnostic? = nil,
        sessionID: String? = nil, roundID: String? = nil
    ) {
        self.diagnostic = diagnostic
        self.sessionID = sessionID
        self.roundID = roundID
        self.inputID = inputID
        self.id = id
        self.source = source
        self.title = String(title.prefix(128))
        self.message = String((diagnostic?.detail ?? message).prefix(diagnostic == nil ? 512 : 2048))
        precondition(failureCode.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
        self.failureCode = diagnostic?.code ?? failureCode
        self.time = time
    }
}
public struct OutputFailureSnapshot: Sendable {
    public let revision: UInt64
    public let records: [OutputFailureRecord]
    public let evictedCount: UInt64
    public init(revision: UInt64, records: [OutputFailureRecord], evictedCount: UInt64) {
        self.revision = revision
        self.records = records
        self.evictedCount = evictedCount
    }
}
