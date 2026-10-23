import AgentCore
import Foundation

/// Pure resource-result validation and error projection; no runtime or native effects.
enum ApplicationControlResourcePolicy {
    static func preferenceFailureReason(_ code: String?) -> String {
        switch code {
        case "resource.selection.recognition": "recognitionRequired"
        case "resource.selection.synthesis": "synthesisRequired"
        case "resource.source.invalid": "invalidSource"
        default: "execution"
        }
    }
    static func isResourceCommand(_ intent: ModelResourceIntent) -> Bool {
        switch intent {
        case .download, .cancel, .remove: true
        default: false
        }
    }
    static func failureMessage(_ raw: String) -> String {
        var bytes = Array(raw.utf8.prefix(2048))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
    struct PreferenceValue: Decodable {
        let endpoint: String
        let allowsCellular: Bool
        let useCustomRecognition: Bool
        let useCustomSynthesis: Bool
    }
    static func preferenceValue(_ raw: String) throws -> PreferenceValue {
        guard raw.utf8.count <= 2048,
            let keys = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            Set(keys.keys) == ["endpoint", "allowsCellular", "useCustomRecognition", "useCustomSynthesis"]
        else { throw CommunicationError.invalidPayload }
        let value = try JSONDecoder().decode(PreferenceValue.self, from: Data(raw.utf8))
        guard !value.endpoint.isEmpty, value.endpoint.utf8.count <= 1024 else {
            throw CommunicationError.invalidPayload
        }
        return value
    }
}

/// Deterministic application policy; independent of UI and model availability.
enum ApplicationControlFailurePolicy {
    static func userMessage(source: String, message: String, code: String? = nil) -> String? {
        switch code {
        case "agent.model.tool.undeclaredName": return "模型调用了未声明的工具，本次回复已中止"
        case "agent.model.tool.invalidArguments": return "模型返回的工具参数格式错误，本次回复已中止"
        case "agent.model.tool.argumentsMismatch": return "模型返回的工具参数前后不一致，本次回复已中止"
        case "agent.model.tool.invalidIdentity", "agent.model.tool.sequenceMismatch":
            return "模型返回的工具调用信息不一致，本次回复已中止"
        case "agent.model.transport": return "模型连接失败，请检查网络后重试"
        case "agent.model.httpStatus", "agent.model.provider": return "模型服务请求失败，本次回复已中止"
        case let code? where code.hasPrefix("agent.model."): return "模型响应格式异常，本次回复已中止"
        case let code? where code.hasPrefix("agent.generation."): return "模型输出的指令格式异常，本次回复已中止"
        case "vision.pose.failed", "vision.pipeline.failed", "vision.input.failed":
            return "姿态识别已停止，请查看日志后重试"
        case "vision.presentation.failed": return "姿态绘制失败，请查看日志"
        case "vision.pose.stalled": return "姿态推理长时间未返回，实时影像仍可用"
        case "vision.pose.stale": return "姿态结果持续超时，请查看日志"
        case "vision.input.stalled": return "姿态识别未收到相机帧，请查看日志"
        case "agent.runtime.failed": return "对话处理失败，请查看日志"
        case "agent.context.publication": return "对话上下文更新失败，本次回复已中止"
        default:
            return source == "speechPerception" && message.hasPrefix("agent.error: speech perception:") ? "我没听清" : nil
        }
    }
    static func categoryTitle(_ category: AgentFailureDiagnostic.Category) -> String {
        switch category {
        case .modelResponse: "模型响应异常"
        case .modelTransport: "模型连接异常"
        case .generation: "指令生成异常"
        case .context: "上下文异常"
        case .runtime: "Agent 运行异常"
        }
    }

}

/// Application state classification, independent of native drivers and UI types.
enum ApplicationControlBluetoothState: String, Sendable {
    case disconnected, connecting, connected
    static func isConnectionCondition(_ event: ContainerFailureEvent) -> Bool {
        event.module == "platform" && event.component == "connectivity.bluetooth"
            && ["bluetooth.unavailable", "bluetooth.deviceUnavailable", "bluetooth.connectionUnavailable"].contains(
                event.code)
    }
    static func environment(_ value: String) throws -> Self? {
        guard let outer = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
            let raw = outer["bluetooth"]
        else { return nil }
        guard let text = raw as? String,
            let facts = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let connection = facts["connection"] as? String,
            let availability = facts["availability"] as? String,
            ["idle", "connecting", "connected", "disconnecting", "failed"].contains(connection),
            ["unknown", "available", "poweredOff", "denied", "unsupported"].contains(availability)
        else { throw CommunicationError.invalidPayload }
        guard availability == "available" else { return .disconnected }
        if connection == "connected" { return .connected }
        let recovery = facts["recovery"] as? String ?? "idle"
        if connection == "connecting" || ["cleaning", "waiting", "connecting"].contains(recovery) {
            return .connecting
        }
        return .disconnected
    }
}
