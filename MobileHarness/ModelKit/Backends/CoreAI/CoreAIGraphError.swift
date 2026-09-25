public enum CoreAIGraphError: Error, Sendable {
    case functionNotFound(String)
    case statefulGraphUnsupported([String])
    case unknownInput(String)
    case shapeMismatch(input: String, expected: [Int], got: [Int])
    case missingOutput(String)
    case dtypeMismatch(input: String, expected: String)
    case unsupportedScalarType(String)
    case inputSetMismatch
}
