import Foundation

public struct ToolResponse: Equatable, Sendable {
    public let callID: UUID
    public let value: String
    public let isError: Bool
    /// Feedback transport failure is independent of the handler outcome.
    public let deliveryFailure: String?
    public init(callID: UUID, value: String, isError: Bool = false, deliveryFailure: String? = nil) {
        self.callID = callID
        self.value = value
        self.isError = isError
        self.deliveryFailure = deliveryFailure.map { String($0.prefix(512)) }
    }
}
