import Foundation

public enum ModelRequestLogUpdate: Sendable {
    case request(method: String, url: String, headers: [String: String], body: Data, at: Date)
    case response(status: Int, headers: [String: String], at: Date)
    case bytes(Data, at: Date)
    case finished(at: Date, error: String?)
}
public struct ModelRequestLog: Sendable {
    public let requestJSON: String
    public let responseJSON: String
    public let format: String
    public let captureState: String
    public init(requestJSON: String, responseJSON: String, format: String = "local", captureState: String = "completed")
    {
        self.requestJSON = requestJSON
        self.responseJSON = responseJSON
        self.format = format
        self.captureState = captureState
    }
}
