import Foundation
import FunctionContracts

extension UIActions {
    public enum VoiceState: String, Sendable { case listening, hearing, processing }

    /// Screen-space target: -1 left/up, +1 right/down; zero looks straight ahead.
    public struct Gaze: Sendable, Equatable {
        public let x: Double
        public let y: Double
    }
    public enum GazeError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidTarget
        public var executionFailureCode: ActionExecutionFailureCode { .invalidArguments }
    }

    public enum PoseError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidPayload
        public var executionFailureCode: ActionExecutionFailureCode { .invalidArguments }
    }

    public enum PresentationError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
        case invalidText
        case invalidCall
        public var executionFailureCode: ActionExecutionFailureCode { .invalidArguments }
    }
}

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
