import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore
import StorageFiles

/// One run's latest failed model request; it never schedules work or retries a request.
actor WriterDiagnosticCapture {
    private(set) var latest: WriterFailureDiagnostic?
    func record(_ diagnostic: WriterFailureDiagnostic) { latest = diagnostic }
    func clear() { latest = nil }
}

enum WriterDiagnostics {
    static func make(
        _ error: any Error, stage: String, details: [String: String] = [:],
        request: WriterFailureDiagnostic? = nil, depth: Int = 0
    ) -> WriterFailureDiagnostic {
        if depth < 4, let combined = error as? WriterCleanupFailure {
            return .init(
                category: "cleanup", code: "writer.cleanup", stage: "Cleanup",
                message: "Writing failed and cleanup did not finish.",
                details: details,
                causes: [
                    make(combined.primary, stage: stage, details: details, request: request, depth: depth + 1),
                    make(combined.cleanup, stage: "Cleanup", depth: depth + 1),
                ])
        }
        if depth < 4, let model = error as? ModelFailure {
            let primary = make(model.underlying, stage: stage, details: details, request: request, depth: depth + 1)
            guard !model.cleanupErrors.isEmpty else { return primary }
            return .init(
                category: "cleanup", code: "writer.model.cleanup", stage: "Model cleanup",
                message: "The model request failed and model cleanup did not finish.",
                details: details,
                causes: [primary]
                    + model.cleanupErrors.prefix(4).map { make($0, stage: "Model cleanup", depth: depth + 1) })
        }
        if depth < 4, let exhausted = error as? WriterRecoveryFailure {
            let last = make(exhausted.underlying, stage: stage, details: details, request: request, depth: depth + 1)
            if last.details["recoveryExhausted"] == "true" { return last }
            var evidence = last.details
            evidence["recoveryPhase"] = exhausted.phase
            evidence["attempts"] = String(exhausted.attempts)
            evidence["recoveryExhausted"] = "true"
            return .init(
                category: last.category, code: last.code, stage: last.stage,
                message: last.message + " Recovery failed after \(exhausted.attempts) attempts.",
                details: evidence, causes: [last])
        }
        if let request {
            if let value = error as? WriterFailure, request.code != "writer." + value.rawValue {
                let primary = make(error, stage: stage, details: details, depth: depth + 1)
                return .init(
                    category: primary.category, code: primary.code, stage: primary.stage,
                    message: primary.message, details: primary.details, causes: [request])
            }
            return request
        }
        var evidence = details
        if let model = error as? any ChatFailureProviding {
            let failure = model.chatFailure
            evidence["providerStage"] = failure.stage.rawValue
            evidence["httpStatus"] = failure.statusCode.map(String.init)
            evidence["networkCode"] = failure.networkCode.map(String.init)
            evidence["networkReason"] = failure.networkReason?.rawValue
            evidence["providerRequestID"] = failure.requestID
            evidence["providerCode"] = failure.providerCode
            evidence["providerType"] = failure.providerType
            evidence["providerParameter"] = failure.providerParameter
            evidence["providerMessage"] = failure.providerMessage
            evidence["event"] = failure.event
            evidence["field"] = failure.field
            evidence["tool"] = failure.toolName
            if failure.reason == .transport {
                let kind = failure.networkReason?.rawValue ?? "unknown"
                let message: String
                switch failure.networkReason {
                case .timeout: message = "The model request timed out while waiting for network data."
                case .dns: message = "Could not resolve the model service address."
                case .tls: message = "The model service TLS connection or certificate verification failed."
                case .offline: message = "The network was unavailable and the model request did not finish."
                case .connection: message = "The connection to the model service failed or was interrupted."
                case .cancelled: message = "The underlying network request was cancelled."
                default: message = "Model network transport failed without a more specific cause."
                }
                return .init(
                    category: "modelTransport", code: "writer.network." + kind, stage: stage,
                    message: message, details: evidence)
            }
            if failure.reason == .httpStatus {
                let status = failure.statusCode.map(String.init) ?? "unknown"
                return .init(
                    category: "modelHTTP", code: "writer.http.\(status)", stage: stage,
                    message: (failure.statusCode.map { "The model service returned HTTP \($0)." }
                        ?? "The model service returned an HTTP error without a status code.")
                        + (failure.providerMessage.map { " " + $0 } ?? ""),
                    details: evidence)
            }
            if failure.reason == .providerFailure {
                return .init(
                    category: "modelProvider", code: "writer.provider.failed", stage: stage,
                    message: "The model service reported an execution failure.", details: evidence)
            }
            return .init(
                category: "modelResponse", code: "writer.model." + failure.reason.rawValue, stage: stage,
                message: "The model response failed protocol validation.", details: evidence)
        }
        if let capability = error as? CapabilityError {
            evidence["capabilityReason"] = String((capability.errorDescription ?? "").prefix(512))
            return .init(
                category: "configuration", code: "writer.model.capability", stage: stage,
                message: "The model capability or request configuration is insufficient.", details: evidence)
        }
        if let storage = error as? StorageFailure {
            evidence["component"] = storage.component
            evidence["operation"] = storage.operation
            return .init(
                category: "storage", code: "writer.storage." + storage.code.rawValue, stage: stage,
                message: "Could not read or write project or history data.", details: evidence,
                causes: depth < 4
                    ? storage.cleanupErrors.prefix(4).map { make($0, stage: "Storage cleanup", depth: depth + 1) } : [])
        }
        if error is FileStorageError || error is DocumentStorageError || error is RecordStorageError
            || error is WriterHistoryError
        {
            let code = String(describing: error)
            evidence["storageCode"] = code
            return .init(
                category: "storage", code: "writer.storage." + code, stage: stage,
                message: "Project or history storage failed: " + code, details: evidence)
        }
        if let tool = error as? WriterToolFailure {
            evidence.merge(tool.context) { _, new in new }
            evidence["toolError"] = tool.description
            let toolStage: String
            switch tool.context["command"] {
            case "start", "resume": toolStage = "Workspace preparation"
            case "render": toolStage = "Rendering"
            case "finish": toolStage = "Publishing"
            case "edit", "replace", "move", "remove", "removeTree", "restore": toolStage = "File editing"
            case "read", "list", "search", "diff": toolStage = "File reading"
            default: toolStage = stage
            }
            return .init(
                category: "tool", code: "writer.tool.failed", stage: toolStage,
                message: "Project tool execution failed: " + tool.description, details: evidence)
        }
        if error is WriterContentFormatFailure {
            return .init(
                category: "modelResponse", code: "writer.content.markdownWrapper", stage: stage,
                message:
                    "The source response had an outer Markdown fence. The write was aborted without committing source.",
                details: evidence)
        }
        if let value = error as? WriterFailure {
            let message: String
            switch value {
            case .unsupportedModel: message = "The selected model does not support Writer’s native tools."
            case .incomplete: message = "The model response ended early. The draft was kept unpublished."
            case .capacity: message = "The Writer request or context exceeded its protocol limit."
            case .invalidOutput: message = "Model output violated the Writer protocol."
            case .unavailable: message = "A capability required by Writer is unavailable."
            case .cancelled: message = "The Writer task was cancelled."
            }
            return .init(
                category: value == .unsupportedModel ? "configuration" : "workflow",
                code: "writer." + value.rawValue, stage: stage, message: message, details: evidence)
        }
        if error is CancellationError {
            return .init(
                category: "cancellation", code: "writer.cancelled", stage: stage,
                message: "The operation was cancelled or interrupted.", details: evidence)
        }
        evidence["errorType"] = String(reflecting: type(of: error))
        return .init(
            category: stage.hasPrefix("History") || stage.contains("历史") ? "storage" : "runtime",
            code: "writer.runtime.failed",
            stage: stage, message: "Writer execution failed.", details: evidence)
    }

    static func describe(_ failure: WriterFailureDiagnostic) -> String {
        ([failure.message, "category=\(failure.category)", "code=\(failure.code)", "stage=\(failure.stage)"]
            + failure.details.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
            + failure.causes.enumerated().map { "cause[\($0.offset)]:\n" + describe($0.element) }).joined(
                separator: "\n")
    }

    static func output(_ failure: WriterFailureDiagnostic) -> AgentFailureDiagnostic {
        let category: AgentFailureDiagnostic.Category =
            failure.category == "modelTransport" || failure.category == "modelHTTP"
            ? .modelTransport
            : ["modelResponse", "modelProvider"].contains(failure.category) ? .modelResponse : .runtime
        return .init(category: category, code: failure.code, detail: describe(failure))
    }
}

extension WriterFailureDiagnostic {
    var storageValue: ModelFailureDiagnostic {
        .init(
            category: category, code: code, stage: stage, message: message,
            details: details, causes: causes.map(\.storageValue))
    }
}
