import Foundation

public struct AgentID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let speechPerception = AgentID(rawValue: "speechPerception")
    public static let visionPerception = AgentID(rawValue: "visionPerception")
    public static let photographer = AgentID(rawValue: "photographer")
    public static let assistant = AgentID(rawValue: "assistant")
}
