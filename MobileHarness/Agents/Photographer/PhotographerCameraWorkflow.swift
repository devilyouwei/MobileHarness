import AgentCore
import Foundation

/// One camera operation, correlated completion and no native I/O.
struct PhotographerCameraWorkflow {
    private struct Pending {
        let requestID: UUID
        let input: AgentInput
    }
    private var pending: Pending?
    private(set) var lastResult: ToolResult?
    private static let permissions = ["open", "close", "flip", "retry", "savePhoto", "ignorePhoto"].map {
        InternalTool(
            path: "Camera.Capture." + $0, required: $0 == "flip" ? ["facing"] : [],
            optional: $0 == "savePhoto" || $0 == "ignorePhoto" ? ["photoID"] : [])
    }
    static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try capabilities.adding(internalTools: permissions)
    }
    mutating func reset() { pending = nil }
    mutating func retire(_ id: UUID) {
        if pending?.requestID == id { pending = nil }
    }
    mutating func receive(_ input: AgentInput, rootSessionID: UUID) throws -> (AgentOutput, AgentInput) {
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
            _ = try message.validatedSize()
            if intent.operation == .cancel {
                guard input.metadata.origin == .external, input.metadata.source == "runtime",
                    input.sessionID == rootSessionID, input.id == intent.requestID,
                    pending == nil || pending?.requestID == intent.requestID
                else { throw CommunicationError.unauthorized }
                pending = nil
                return (.control("photographer.camera.cancelled"), input)
            }
            let human =
                input.metadata.origin == .external && input.metadata.incarnation == nil
                && input.metadata.source == "user" && input.sessionID == rootSessionID
            let assistant =
                input.metadata.origin == .agent && input.metadata.incarnation != nil
                && input.metadata.source == AgentID.assistant.rawValue
            guard human || assistant else { throw CommunicationError.unauthorized }
            guard pending == nil else { throw CommunicationError.capacityExceeded }
            guard
                let permission = Self.permissions.first(where: {
                    $0.path == "Camera.Capture." + intent.operation.rawValue
                })
            else {
                throw CommunicationError.invalidPayload
            }
            var arguments = intent.facing.map { ["facing": $0.rawValue] } ?? [:]
            if let id = intent.photoID { arguments["photoID"] = id.uuidString }
            let permitted = try permission.call(arguments)
            let call = ToolCall(id: intent.requestID, toolPath: permitted.toolPath, arguments: permitted.arguments)
            pending = Pending(requestID: intent.requestID, input: input)
            return (.toolCall(call), input)
        default: throw CommunicationError.invalidPayload
        }
    }
}
