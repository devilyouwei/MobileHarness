import AgentCore
import Foundation
import StorageCore

/// One camera operation, correlated completion and no native I/O.
struct PhotographerCameraWorkflow {
    private struct Pending {
        let requestID: String
        let input: AgentInput
    }
    private var pending: Pending?
    private(set) var lastResult: ToolResult?
    private static let permissions = ["open", "close", "flip", "retry", "takePhoto", "savePhoto", "ignorePhoto"].map {
        InternalTool(
            path: "Camera.Capture." + $0, required: $0 == "flip" ? ["facing"] : [],
            optional: $0 == "savePhoto" || $0 == "ignorePhoto" ? ["mediaID"] : [])
    }
    private static let perceptionPermissions = ["open", "close", "flip", "retry"].map {
        InternalTool(path: "Camera.Perception." + $0 + "Vision", required: $0 == "flip" ? ["facing"] : [])
    }
    static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try capabilities.adding(internalTools: permissions + perceptionPermissions)
    }
    var requestID: String? { pending?.requestID }
    mutating func reset() { pending = nil }
    mutating func retire(_ id: String) {
        if pending?.requestID == id { pending = nil }
    }
    mutating func receive(_ input: AgentInput, rootSessionID: String) throws -> (AgentOutput, AgentInput) {
        switch input.payload {
        case .toolResult(let result):
            guard input.metadata.origin == .runtime, input.metadata.source == "runtime",
                let active = pending, active.requestID == result.callID, active.input.sessionID == input.sessionID
            else { throw CommunicationError.invalidPayload }
            pending = nil
            lastResult = result
            return (
                .control(result.isError ? "photographer.camera.failed" : "photographer.camera.finished"), active.input
            )
        case .observation(let message):
            guard message.contract == PhotographerCameraIntent.contract, let intent = message.photographerCamera,
                input.metadata.contract == PhotographerCameraIntent.contract, input.metadata.version == 1
            else { throw CommunicationError.invalidPayload }
            try input.validate(message)
            if intent.operation == .cancel {
                guard input.metadata.origin == .local, input.metadata.source == "runtime",
                    input.sessionID == rootSessionID, input.id == intent.requestID,
                    pending == nil || pending?.requestID == intent.requestID
                else { throw CommunicationError.unauthorized }
                pending = nil
                return (.control("photographer.camera.cancelled"), input)
            }
            let human =
                input.metadata.origin == .local && input.metadata.incarnation == nil
                && input.metadata.source == "user" && input.sessionID == rootSessionID
            let assistant =
                input.metadata.origin == .agent && input.metadata.incarnation != nil
                && input.metadata.source == AgentID.assistant.rawValue
            guard human || assistant else { throw CommunicationError.unauthorized }
            guard pending == nil else { throw CommunicationError.capacityExceeded }
            guard
                let permission = (Self.permissions + Self.perceptionPermissions).first(where: {
                    $0.path == intent.operation.actionPath
                })
            else {
                throw CommunicationError.invalidPayload
            }
            var arguments = intent.facing.map { ["facing": $0.rawValue] } ?? [:]
            if let id = intent.mediaID { arguments["mediaID"] = id }
            let permitted = try permission.call(arguments)
            let call = ToolCall(id: intent.requestID, toolPath: permitted.toolPath, arguments: permitted.arguments)
            pending = Pending(requestID: intent.requestID, input: input)
            return (.toolCall(call), input)
        default: throw CommunicationError.invalidPayload
        }
    }
}
