import Foundation

/// Immutable Agent-local capability snapshot, shared by prompt exposure, resolution and validation.
public struct CapabilityRegistry: Sendable {
    public let actions: [ActionRegistration]
    public let tools: [ToolRegistration]
    public let channels: Set<String>

    public init(actions: [ActionRegistration] = [], tools: [ToolRegistration] = [], channels: Set<String> = ["main"])
        throws
    {
        guard actions.count + tools.count <= 128, channels.count <= 16 else { throw GenerationError.limitExceeded }
        let aliases = actions.map(\.alias) + tools.map(\.alias)
        guard Set(aliases).count == aliases.count else { throw GenerationError.duplicateAlias }
        guard aliases.allSatisfy({ Self.validName($0) && !$0.hasPrefix("channel.") }),
            channels.allSatisfy(Self.validName),
            actions.allSatisfy({
                Self.validName($0.defaultChannel) && Self.validName($0.path.module) && Self.validName($0.path.function)
            }),
            tools.allSatisfy({ Self.validName($0.path) })
        else { throw GenerationError.invalidParameters }
        for action in actions {
            try Self.validateSchema(required: action.requiredParameters, optional: action.optionalParameters)
        }
        for tool in tools {
            try Self.validateSchema(required: tool.requiredParameters, optional: tool.optionalParameters)
        }
        self.actions = actions
        self.tools = tools
        self.channels = channels.union(actions.map(\.defaultChannel))
        guard self.channels.count <= 16 else { throw GenerationError.limitExceeded }
    }

    public func resolveAction(_ alias: String, parameters: [String: String], channel: String? = nil) throws
        -> ActionCall
    {
        guard let action = actions.first(where: { $0.alias == alias }) else { throw GenerationError.unknownCapability }
        try Self.validate(parameters, required: action.requiredParameters, optional: action.optionalParameters)
        let selected = channel ?? action.defaultChannel
        guard channels.contains(selected) else { throw GenerationError.forbiddenChannel }
        return ActionCall(actionPath: action.path, channel: selected, parameters: parameters)
    }

    public func resolveTool(_ alias: String, arguments: [String: String], id: UUID = UUID()) throws -> ToolCall {
        guard let tool = tools.first(where: { $0.alias == alias }) else { throw GenerationError.unknownCapability }
        try Self.validate(arguments, required: tool.requiredParameters, optional: tool.optionalParameters)
        return ToolCall(id: id, toolPath: tool.path, arguments: arguments)
    }

    public func permits(_ call: ActionCall) -> Bool {
        channels.contains(call.channel)
            && actions.contains {
                $0.path == call.actionPath
                    && (try? Self.validate(
                        call.parameters, required: $0.requiredParameters, optional: $0.optionalParameters)) != nil
            }
    }

    public func permits(_ call: ToolCall) -> Bool {
        tools.contains {
            $0.path == call.toolPath
                && (try? Self.validate(call.arguments, required: $0.requiredParameters, optional: $0.optionalParameters))
                    != nil
        }
    }

    static func validName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || b == 95 }
        guard !bytes.isEmpty, bytes.count <= 64, letter(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
    }

    private static func validateSchema(required: Set<String>, optional: Set<String>) throws {
        guard required.isDisjoint(with: optional), required.count + optional.count <= 32,
            required.union(optional).allSatisfy(validName)
        else { throw GenerationError.invalidParameters }
    }

    private static func validate(_ values: [String: String], required: Set<String>, optional: Set<String>) throws {
        let keys = Set(values.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)),
            values.count <= 32, values.allSatisfy({ validName($0.key) && $0.value.utf8.count <= 4096 })
        else { throw GenerationError.invalidParameters }
    }
}
