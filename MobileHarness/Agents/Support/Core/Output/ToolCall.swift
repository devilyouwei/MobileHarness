import Foundation

public struct ToolCall: Equatable, Sendable {
    public let id: String
    public let toolPath: String
    public let arguments: [String: String]
    public init(id: String, toolPath: String, arguments: [String: String] = [:]) {
        self.id = id
        self.toolPath = toolPath
        self.arguments = arguments
    }
}
