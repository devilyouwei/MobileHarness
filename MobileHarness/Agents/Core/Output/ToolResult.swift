import Foundation

public struct ToolResult: Equatable, Sendable {
    public let callID: UUID
    public let value: String
    public let isError: Bool
    public init(callID: UUID, value: String, isError: Bool = false) {
        self.callID = callID
        self.value = value
        self.isError = isError
    }
}
