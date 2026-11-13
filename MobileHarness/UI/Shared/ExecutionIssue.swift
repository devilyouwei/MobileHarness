import Foundation

/// Display-only execution issue; no device state or SDK fault classification.
public struct ExecutionIssue: Identifiable, Sendable, Equatable {
    public struct Context: Sendable, Equatable {
        public let workerID: String
        public let sessionID: String?
        public let inputID: String?
        public let callID: String?
        public let roundID: String?
        public init(
            workerID: String, sessionID: String? = nil, inputID: String? = nil, callID: String? = nil,
            roundID: String? = nil
        ) {
            self.workerID = workerID
            self.sessionID = sessionID
            self.inputID = inputID
            self.callID = callID
            self.roundID = roundID
        }
    }
    public let inputID: String?
    public let context: Context?
    public let failureCode: String?
    public let id: String
    public let title: String
    public let source: String
    public let message: String
    public let userMessage: String?
    public let category: String?
    public let time: Date
    public init(
        id: String = UUID().uuidString, title: String, source: String, message: String, time: Date = Date(),
        failureCode: String? = nil, context: Context? = nil, inputID: String? = nil, userMessage: String? = nil,
        category: String? = nil
    ) {
        self.inputID = inputID ?? context?.inputID
        self.id = id
        self.title = String(title.prefix(128))
        self.source = String(source.prefix(64))
        self.category = category.map { String($0.prefix(64)) }
        self.message = String(message.prefix(category == nil ? 512 : 2048))
        self.userMessage = userMessage.map { String($0.prefix(512)) }
        precondition(failureCode.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
        self.failureCode = failureCode
        self.context = context
        self.time = time
    }
}

@MainActor
public protocol ExecutionFailureReporting: AnyObject, Sendable {
    func recordFailure(
        title: String, source: String, message: String, failureCode: String?, context: ExecutionIssue.Context?)
}
