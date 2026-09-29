import AgentCore

public enum ActionExecutionError: Error, Equatable, Sendable {
    case missingHandler(ActionPath)
    case duplicateDefinition(ActionPath)
    case invalidDefinition(ActionPath)
    case definitionCapacityExceeded
    case invalidInvocation
}
