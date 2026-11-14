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
        let useLocalDecision: Bool?
    }
    static func preferenceValue(_ raw: String) throws -> PreferenceValue {
        guard raw.utf8.count <= 2048,
            let keys = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            Set(keys.keys).isSubset(of: [
                "endpoint", "allowsCellular", "useCustomRecognition", "useCustomSynthesis", "useLocalDecision",
            ])
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
        case "agent.model.tool.undeclaredName": return "The model called an unavailable tool. The reply stopped."
        case "agent.model.tool.invalidArguments": return "The model sent invalid tool arguments. The reply stopped."
        case "agent.model.tool.argumentsMismatch":
            return "The model sent inconsistent tool arguments. The reply stopped."
        case "agent.model.tool.invalidIdentity", "agent.model.tool.sequenceMismatch":
            return "The model sent inconsistent tool information. The reply stopped."
        case "agent.model.transport": return "Could not reach the model. Check your connection and try again."
        case "agent.model.httpStatus", "agent.model.provider": return "The model service failed. The reply stopped."
        case let code? where code.hasPrefix("agent.model."):
            return "The model returned an invalid response. The reply stopped."
        case let code? where code.hasPrefix("agent.generation."):
            return "The model returned an invalid command. The reply stopped."
        case "vision.pose.failed", "vision.pipeline.failed", "vision.input.failed":
            return "Pose recognition stopped. Try again."
        case "vision.presentation.failed": return "Could not display pose results."
        case "vision.pose.stalled": return "Pose recognition stalled. Live video is still available."
        case "vision.pose.stale": return "Pose recognition keeps timing out."
        case "vision.input.stalled": return "Pose recognition received no camera frames."
        case "agent.runtime.failed": return "Could not continue the conversation."
        case "agent.context.publication": return "Could not update the conversation. The reply was stopped."
        default:
            return source == "speechPerception" && message.hasPrefix("agent.error: speech perception:")
                ? "I didn't catch that." : nil
        }
    }
    static func categoryTitle(_ category: AgentFailureDiagnostic.Category) -> String {
        switch category {
        case .modelResponse: "Model response failure"
        case .modelTransport: "Model connection failure"
        case .generation: "Generation failure"
        case .context: "Context failure"
        case .runtime: "Agent runtime failure"
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
