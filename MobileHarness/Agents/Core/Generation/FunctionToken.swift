/// Protocol-level events for natural text, self-closing XML Actions and XML channel boundaries.
/// Not model tokenizer tokens; text events may contain one or many characters.
/// Events remain inside the Agent. A nil channel means the registered action default.
public enum FunctionToken: Equatable, Sendable {
    case text(String, channel: String?)
    case action(name: String, parameters: [String: String], channel: String?)
    /// Flush text at a channel boundary, including an empty scope.
    case boundary
    case scheduling(SchedulingDirective)
}

public enum GenerationError: Error, Equatable, Sendable {
    case malformedMarkup, invalidUTF8, invalidEntity, incompleteDocument, closed, limitExceeded
    case unknownCapability, duplicateAlias, invalidParameters, forbiddenChannel
}

/// Structured execution boundaries, scoped to the trusted envelope's Agent/session/input.
public enum SchedulingDirective: Equatable, Sendable {
    case beginWait, endWait
}

/// Ordered generation output. Never discard scheduling boundaries when forwarding actions.
public enum GenerationEvent: Equatable, Sendable {
    case action(ActionCall)
    case tool(ToolCall)
    case scheduling(SchedulingDirective)

    public var actionCall: ActionCall? {
        if case .action(let call) = self { call } else { nil }
    }
}
