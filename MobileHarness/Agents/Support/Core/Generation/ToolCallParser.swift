import Foundation

/// Consumes a complete model-native tool call; XML actions do not enter this protocol.
public enum ToolCallParser {
    public static func parse(id: String, alias: String, argumentsJSON: Data, capabilities: CapabilityRegistry) throws
        -> ToolCall
    {
        let arguments: [String: String]
        do { arguments = try JSONDecoder().decode([String: String].self, from: argumentsJSON) } catch {
            throw GenerationError.invalidParameters
        }
        return try capabilities.resolveTool(alias, arguments: arguments, id: id)
    }
}
