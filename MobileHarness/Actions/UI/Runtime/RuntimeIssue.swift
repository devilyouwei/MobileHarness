import Foundation
import FunctionContracts

/// Presentation values already classified by the owning application Agent.
public struct RuntimeIssue: Sendable {
    public let id: String
    public let title: String
    public let source: String
    public let message: String
    public let time: Date
    public let failureCode: String?
    public let workerID: String
    public let sessionID: String?
    public let inputID: String?
    public let roundID: String?
    public let callID: String?
    public let category: String?
    public let userMessage: String?
    public init(parameters: [String: String]) throws {
        let args = ActionArguments(parameters)
        try args.validateAllowedKeys([
            "id", "title", "source", "message", "time", "failureCode", "workerID", "sessionID", "inputID",
            "roundID", "callID", "category", "userMessage",
        ])
        id = try args.requiredString("id", maximumUTF8Bytes: 512)
        title = try args.requiredString("title", maximumUTF8Bytes: 1024)
        source = try args.requiredString("source", maximumUTF8Bytes: 64)
        message = try args.requiredString("message", maximumUTF8Bytes: 10_240)
        workerID = try args.requiredString("workerID", maximumUTF8Bytes: 256)
        let rawTime = try args.requiredString("time", maximumUTF8Bytes: 64)
        guard let seconds = Double(rawTime), seconds.isFinite else { throw UIActions.PresentationError.invalidText }
        time = Date(timeIntervalSince1970: seconds)
        func optional(_ key: String, limit: Int) throws -> String? {
            guard parameters[key] != nil else { return nil }
            return try args.requiredString(key, maximumUTF8Bytes: limit)
        }
        failureCode = try optional("failureCode", limit: 64)
        sessionID = try optional("sessionID", limit: 128)
        inputID = try optional("inputID", limit: 128)
        roundID = try optional("roundID", limit: 128)
        callID = try optional("callID", limit: 128)
        category = try optional("category", limit: 256)
        userMessage = try optional("userMessage", limit: 2048)
    }
}
