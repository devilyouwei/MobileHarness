import Foundation
import FunctionContracts

/// Agent-owned failure classification; producers retain the original typed cause.
public struct AgentFailureDiagnostic: Equatable, Sendable {
    public enum Category: String, Sendable {
        case modelResponse, modelTransport, generation, context, runtime
    }
    public let category: Category
    public let code: String
    public let detail: String
    public init(category: Category, code: String, detail: String) {
        precondition(!code.isEmpty && code.utf8.count <= 64)
        self.category = category
        self.code = code
        self.detail = String(detail.prefix(2048))
    }
}

public enum AgentOutput: Equatable, Sendable {
    case communication(CommunicationAction)
    case rejectedCall(CallRejection)
    case actionCall(ActionCall)
    case actionControl(ActionControl)
    case toolCall(ToolCall)
    case control(String)
    case roundBranchSealed(CallLane, String)
    case roundStarted(String)
    case roundFinished(String)
    public var kind: OutputKind {
        switch self {
        case .communication: .communication
        case .rejectedCall(let rejection): rejection.kind == .tool ? .toolCall : .actionCall
        case .actionCall: .actionCall
        case .toolCall: .toolCall
        case .control, .actionControl: .control
        case .roundStarted, .roundBranchSealed, .roundFinished: .control
        }
    }
}

public struct ExecutionEnd: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case completed, interrupted, cancelled, failed }
    public let id: String
    public let reason: Reason
    public let cleanupConfirmed: Bool
    public let failure: String?
    public init(id: String, reason: Reason = .completed, cleanupConfirmed: Bool = true, failure: String? = nil) {
        self.id = id
        self.reason = reason
        self.cleanupConfirmed = cleanupConfirmed
        self.failure = failure.map { String($0.prefix(512)) }
    }
}

/// Addressed runtime feedback. An Action, a model round and a session interruption have distinct identities.
public enum ExecutionFeedback: Codable, Equatable, Sendable {
    public static let contract = "action.execution.event.v1"
    public static let actionResultContract = "action.result.v1"
    public static let toolResultContract = "tool.result.v1"
    public static let controlResultContract = "action.control.result.v1"

    public var protocolID: String {
        switch self {
        case .actionFinished: Self.actionResultContract
        case .actionControlReceipt: Self.controlResultContract
        default: Self.contract
        }
    }
    case actionStarted(
        roundID: String?, callID: String?, executionID: String? = nil, controlCapabilities: Set<String>? = nil,
        path: ActionPath? = nil)
    case actionStateChanged(ActionExecutionStateChange)
    case actionControlReceipt(ActionControlReceipt)
    case actionFinished(ActionResult)
    case roundStarted(String)
    case roundBranchFinished(CallLane, ExecutionEnd)
    case roundFinished(ExecutionEnd)
    case interruptionStarted(String)
    case interruptionFinished(ExecutionEnd)
}

public enum OutputKind: String, Codable, Sendable {
    case communication, actionCall, toolCall, control
}

/// Agent call intent; Gateway translates it to an Actions request. source/input/session correlation is carried by OutputEnvelope.
public struct ActionCall: Equatable, Sendable {
    public let actionPath: ActionPath
    public let channel: String
    public let parameters: [String: String]
    public let scope: CallScope?
    public var isWait: Bool { actionPath == Self.waitPath }
    public static let waitPath = ActionPath(domain: "Scheduling", module: "Wait", function: "wait")

    public init(actionPath: ActionPath, channel: String, parameters: [String: String] = [:], scope: CallScope? = nil) {
        self.actionPath = actionPath
        self.channel = channel
        self.parameters = parameters
        self.scope = scope
    }
}

public struct ToolCall: Equatable, Sendable {
    public let id: String
    public let toolPath: String
    public let arguments: [String: String]
    public init(id: String, toolPath: String, arguments: [String: String] = [:]) {
        self.id = id
        self.toolPath = toolPath
        self.arguments = arguments
    }
}
