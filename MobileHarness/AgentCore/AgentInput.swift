import Foundation

public enum InputPayload: Sendable {
    case text(String)
    case event(String)
    case toolResult(ToolResult)
    // Media adapters will add timestamped frame/chunk payloads in P2.
    public var kind: InputKind {
        switch self {
        case .text: .text
        case .event: .event
        case .toolResult: .toolResult
        }
    }
}

public struct AgentInput: Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let payload: InputPayload
    public init(id: UUID = UUID(), sessionID: UUID, payload: InputPayload) {
        self.id = id
        self.sessionID = sessionID
        self.payload = payload
    }
}
