import Foundation

/// Output representation is encoded once and retains its validated immutable domain message.
public struct CommunicationAction: Sendable, Equatable {
    public let id: String
    public let message: AgentMessage
    public let target: AgentID?
    private let content: Data
    public init(id: String? = nil, message: AgentMessage, target: AgentID? = nil) throws {
        self.id = id ?? UUID().uuidString
        self.message = message
        self.target = target
        content = try message.encodedContent()
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.target == rhs.target && lhs.message.contract == rhs.message.contract
            && lhs.content == rhs.content
    }
}
