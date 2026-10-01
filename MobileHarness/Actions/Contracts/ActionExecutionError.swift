public enum ActionExecutionError: Error, Equatable, Sendable {
    case missingHandler(ActionIdentifier)
    case duplicateDefinition(ActionIdentifier)
    case invalidDefinition(ActionIdentifier)
    case definitionCapacityExceeded
    case invalidCompletion
    case invalidInvocation
}
