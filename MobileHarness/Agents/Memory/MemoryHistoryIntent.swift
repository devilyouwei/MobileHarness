import AgentCore
import Foundation

/// Typed human/history host intent; never embedded in framework business enums.
public enum MemoryHistoryIntent: Codable, Sendable, Equatable {
    case startNew
    case summarize(String)
    case refresh
    case delete(String)
    case cancel(String)
    public static let contract = "history.intent"
    public func validate() throws {
        switch self {
        case .summarize(let id), .delete(let id), .cancel(let id):
            guard !id.isEmpty, id.utf8.count <= 128 else { throw CommunicationError.invalidPayload }
        case .startNew, .refresh: break
        }
    }
    public func input(sessionID: String) throws -> AgentInput {
        let requestID: String?
        let source: String
        if case .cancel(let id) = self {
            requestID = id
            source = "runtime"
        } else {
            requestID = nil
            source = "user"
        }
        let message = AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 512, validate: { try $0.validate() })
        let payload = InputPayload.observation(message)
        return ProcessingContext(requestID: requestID, sessionID: sessionID, source: source, rootID: requestID).input(
            payload)
    }
}

extension AgentMessage {
    public var historyIntent: MemoryHistoryIntent? { content(as: MemoryHistoryIntent.self) }
}

extension MemoryHistoryIntent {
    static func taskMessage(_ signal: AgentTaskSignal) throws -> AgentMessage {
        guard signal.businessContract == Self.contract else { throw CommunicationError.unsupportedContract }
        let value = try JSONDecoder().decode(Self.self, from: signal.data)
        if case .cancel = value { throw CommunicationError.unauthorized }
        return AgentMessage(
            contract: signal.businessContract, content: value, maximumBytes: 512, validate: { try $0.validate() })
    }
}
