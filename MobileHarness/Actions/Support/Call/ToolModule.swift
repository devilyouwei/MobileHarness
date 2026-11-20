import ExecutionRuntime
import FunctionContracts

public enum ToolRegistrationError: Error, Equatable, Sendable {
    case invalidDefinition(String)
    case missingHandler(String)
}
public protocol ToolModule: Sendable { var definitions: [ActionBinding] { get } }
