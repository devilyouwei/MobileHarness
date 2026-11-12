import Foundation
import ModelKit

/// A bounded recovery episode, never a budget for successful creative work.
public struct WriterRecoveryFailure: Error, Sendable {
    public let phase: String
    public let attempts: Int
    public let underlying: any Error
}

enum WriterRecovery {
    static let attempts = 3
    static func retryable(_ error: any Error) -> Bool {
        if error is CancellationError || error is WriterCleanupFailure || error is WriterRecoveryFailure {
            return false
        }
        if let model = error as? ModelFailure {
            return model.cleanupErrors.isEmpty && retryable(model.underlying)
        }
        if let provider = error as? any ChatFailureProviding {
            let failure = provider.chatFailure
            switch failure.reason {
            case .transport:
                return failure.networkReason != .tls && failure.networkReason != .cancelled
            case .httpStatus:
                return [408, 409, 425, 429, 500, 502, 503, 504].contains(failure.statusCode ?? 0)
            case .providerFailure:
                return ["overloaded", "server_error", "rate_limit_exceeded", "temporarily_unavailable"].contains(
                    failure.providerCode ?? "")
            case .truncatedStream, .malformedEvent, .invalidText, .invalidToolArguments, .toolArgumentsMismatch,
                .toolSequence, .invalidCompletion:
                return true
            default: return false
            }
        }
        return error is WriterContentFormatFailure || error as? WriterFailure == .incomplete
            || error as? WriterFailure == .invalidOutput
    }
    static func repairableTool(_ error: any Error) -> Bool {
        if let tool = error as? WriterToolFailure { return tool.context["repairable"] != "false" }
        if let failure = error as? WriterFailure { return failure == .invalidOutput || failure == .capacity }
        return error is DecodingError
    }
    static func delay(_ attempt: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(attempt == 1 ? 500 : 1000))
    }
    static func requestFeedback(_ error: any Error, attempt: Int, content: Bool = false) throws -> String {
        let failure = WriterDiagnostics.make(error, stage: content ? "文件内容请求" : "控制请求")
        let value: [String: String] = [
            "origin": "writer.runtime", "status": "failed", "code": failure.code,
            "message": failure.message, "category": failure.category, "stage": failure.stage,
            "details": String(decoding: try JSONEncoder().encode(failure.details), as: UTF8.self),
            "attempt": String(attempt), "maximumAttempts": String(attempts),
            "effect": content
                ? try AgentPrompts.text("Writer/Recovery", "contentEffect")
                : try AgentPrompts.text("Writer/Recovery", "controlEffect"),
            "recovery": content
                ? try AgentPrompts.text("Writer/Recovery", "contentRecovery")
                : try AgentPrompts.text("Writer/Recovery", "controlRecovery"),
        ]
        return try AgentPrompts.text("Writer/Recovery", "observation")
            + String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    static func feedback(_ error: any Error, attempt: Int, repeated: Bool = false) throws -> String {
        let failure = WriterDiagnostics.make(error, stage: "工具恢复")
        let value: [String: String] = [
            "status": "failed", "code": failure.code, "message": failure.message,
            "category": failure.category, "stage": failure.stage,
            "details": String(decoding: try JSONEncoder().encode(failure.details), as: UTF8.self),
            "recoveryAttempt": String(attempt), "maximumAttempts": String(attempts),
            "effect": repeated
                ? try AgentPrompts.text("Writer/Recovery", "repeatedEffect")
                : try AgentPrompts.text("Writer/Recovery", "originalEffect"),
            "recovery":
                try AgentPrompts.text("Writer/Recovery", "toolRecovery"),
        ]
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
