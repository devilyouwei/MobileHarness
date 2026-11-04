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
                category: "cleanup", code: "writer.cleanup", stage: "清理", message: "创作失败，且清理未完全完成。",
                details: details,
                causes: [
                    make(combined.primary, stage: stage, details: details, request: request, depth: depth + 1),
                    make(combined.cleanup, stage: "清理", depth: depth + 1),
                ])
        }
        if depth < 4, let model = error as? ModelFailure {
            let primary = make(model.underlying, stage: stage, details: details, request: request, depth: depth + 1)
            guard !model.cleanupErrors.isEmpty else { return primary }
            return .init(
                category: "cleanup", code: "writer.model.cleanup", stage: "模型清理", message: "模型请求失败，且模型资源清理未完全完成。",
                details: details,
                causes: [primary] + model.cleanupErrors.prefix(4).map { make($0, stage: "模型清理", depth: depth + 1) })
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
                message: last.message + " 已尝试\(exhausted.attempts)次恢复，仍未成功。",
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
                case .timeout: message = "模型请求等待网络数据超时。"
                case .dns: message = "无法解析模型服务地址。"
                case .tls: message = "模型服务 TLS 连接或证书校验失败。"
                case .offline: message = "网络不可用，模型请求未完成。"
                case .connection: message = "模型服务连接失败或连接中断。"
                case .cancelled: message = "底层网络请求被取消。"
                default: message = "模型网络传输失败，底层原因未能进一步分类。"
                }
                return .init(
                    category: "modelTransport", code: "writer.network." + kind, stage: stage,
                    message: message, details: evidence)
            }
            if failure.reason == .httpStatus {
                let status = failure.statusCode.map(String.init) ?? "unknown"
                return .init(
                    category: "modelHTTP", code: "writer.http.\(status)", stage: stage,
                    message: (failure.statusCode.map { "模型服务返回 HTTP \($0)。" } ?? "模型服务返回 HTTP 错误，状态码未提供。")
                        + (failure.providerMessage.map { " " + $0 } ?? ""),
                    details: evidence)
            }
            if failure.reason == .providerFailure {
                return .init(
                    category: "modelProvider", code: "writer.provider.failed", stage: stage,
                    message: "模型服务报告执行失败。", details: evidence)
            }
            return .init(
                category: "modelResponse", code: "writer.model." + failure.reason.rawValue, stage: stage,
                message: "模型响应未能通过协议校验。", details: evidence)
        }
        if let capability = error as? CapabilityError {
            evidence["capabilityReason"] = String((capability.errorDescription ?? "").prefix(512))
            return .init(
                category: "configuration", code: "writer.model.capability", stage: stage,
                message: "模型能力或请求配置不满足要求。", details: evidence)
        }
        if let storage = error as? StorageFailure {
            evidence["component"] = storage.component
            evidence["operation"] = storage.operation
            return .init(
                category: "storage", code: "writer.storage." + storage.code.rawValue, stage: stage,
                message: "作品或历史数据读写失败。", details: evidence,
                causes: depth < 4
                    ? storage.cleanupErrors.prefix(4).map { make($0, stage: "存储清理", depth: depth + 1) } : [])
        }
        if error is FileStorageError || error is DocumentStorageError || error is RecordStorageError
            || error is ConversationHistoryError
        {
            let code = String(describing: error)
            evidence["storageCode"] = code
            return .init(
                category: "storage", code: "writer.storage." + code, stage: stage,
                message: "作品或历史存储操作失败：" + code, details: evidence)
        }
        if let tool = error as? WriterToolFailure {
            evidence.merge(tool.context) { _, new in new }
            evidence["toolError"] = tool.description
            let toolStage: String
            switch tool.context["command"] {
            case "start", "resume": toolStage = "工作区准备"
            case "render": toolStage = "渲染"
            case "finish": toolStage = "发布"
            case "edit", "replace", "move", "remove", "removeTree", "restore", "restoreVersion": toolStage = "文件编辑"
            case "read", "list", "search", "diff", "versions": toolStage = "文件读取"
            default: toolStage = stage
            }
            return .init(
                category: "tool", code: "writer.tool.failed", stage: toolStage,
                message: "作品工具执行失败：" + tool.description, details: evidence)
        }
        if error is WriterContentFormatFailure {
            return .init(
                category: "modelResponse", code: "writer.content.markdownWrapper", stage: stage,
                message: "源码响应包含 Markdown 外层代码围栏，已中止本次写入，未提交为源码。", details: evidence)
        }
        if let value = error as? WriterFailure {
            let message: String
            switch value {
            case .unsupportedModel: message = "所选模型不支持 Writer 所需的原生工具调用。"
            case .incomplete: message = "模型响应未正常完成，草稿未被当作完整作品发布。"
            case .capacity: message = "Writer 请求或上下文超过当前协议边界。"
            case .invalidOutput: message = "模型输出不符合 Writer 协议。"
            case .unavailable: message = "Writer 所需能力尚不可用。"
            case .cancelled: message = "Writer 任务已取消。"
            }
            return .init(
                category: value == .unsupportedModel ? "configuration" : "workflow",
                code: "writer." + value.rawValue, stage: stage, message: message, details: evidence)
        }
        if error is CancellationError {
            return .init(
                category: "cancellation", code: "writer.cancelled", stage: stage,
                message: "当前执行被取消或中断。", details: evidence)
        }
        evidence["errorType"] = String(reflecting: type(of: error))
        return .init(
            category: stage.contains("历史") ? "storage" : "runtime", code: "writer.runtime.failed",
            stage: stage, message: "Writer 执行失败。", details: evidence)
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
    var storageValue: ConversationFailureDiagnostic {
        .init(
            category: category, code: code, stage: stage, message: message,
            details: details, causes: causes.map(\.storageValue))
    }
}
