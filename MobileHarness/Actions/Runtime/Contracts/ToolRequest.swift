import Foundation

public struct ToolRequest: Equatable, Sendable {
    public let id: UUID
    public let toolPath: String
    public let arguments: [String: String]
    public init(id: UUID = UUID(), toolPath: String, arguments: [String: String] = [:]) {
        self.id = id
        self.toolPath = toolPath
        self.arguments = arguments
    }
}
