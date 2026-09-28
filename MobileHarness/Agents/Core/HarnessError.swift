import Foundation

public enum HarnessError: Error, Equatable, Sendable {
    case duplicateAgent, unknownAgent, notRunning, queueFull, unsupportedInput, forbiddenOutput
    case forbiddenFunction, forbiddenTool, missingHandler, duplicateHandler, invalidTransition
}
