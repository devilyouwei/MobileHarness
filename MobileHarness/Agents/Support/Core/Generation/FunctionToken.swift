import Foundation

/// Protocol-level events for natural text, self-closing XML Actions and wait boundaries.
/// Not model tokenizer tokens; text events may contain one or many characters.
/// Events remain inside the Agent; routing belongs to registered capabilities.
public enum FunctionToken: Equatable, Sendable {
    case text(String)
    case action(name: String, parameters: [String: String])
    case scheduling(SchedulingDirective)
}

public enum GenerationError: Error, Equatable, Sendable {
    case malformedMarkup, invalidUTF8, invalidEntity, incompleteDocument, closed, limitExceeded
    case unknownCapability, duplicateAlias, invalidParameters
}

/// Structured execution boundaries, scoped to the trusted envelope's Agent/session/input.
public enum SchedulingDirective: Equatable, Sendable {
    case beginWait, endWait
}

/// A rejected model invocation carries no executable path or arguments.
public struct CallRejection: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case action, tool }
    public let kind: Kind
    public let alias: String
    public let callID: String?
    public let reason: GenerationError

    public init(kind: Kind, alias: String, callID: String? = nil, reason: GenerationError) {
        self.kind = kind
        self.alias = String(alias.prefix(64))
        self.callID = callID
        self.reason = reason
    }
}

/// Ordered generation output. Never discard scheduling boundaries when forwarding actions.
public enum GenerationEvent: Equatable, Sendable {
    case rejected(CallRejection)
    case action(ActionCall)
    /// Code-generated execution, including natural-text presentation. Never model feedback.
    case runtimeAction(ActionCall)
    case tool(ToolCall)
    case scheduling(SchedulingDirective)

    public var actionCall: ActionCall? {
        switch self {
        case .action(let call), .runtimeAction(let call): call
        default: nil
        }
    }
}
