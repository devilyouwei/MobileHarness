import Foundation

/// Immutable Agent-local capability snapshot, shared by prompt exposure, resolution and validation.
public struct CapabilityRegistry: Sendable {
    public let actions: [ActionRegistration]
    public let tools: [ToolRegistration]
    public let internalActions: [InternalAction]
    public let internalTools: [InternalTool]
    public let controls: [ControlRegistration]
    /// Usage guide of the owner's controls; present only together with controls.
    public let controlGuidance: ControlGuidance?
    public let channels: Set<String>
    /// True when a loaded Skill registers the scheduling `wait` (paired scopes and self-closing `time`).
    public let supportsWait: Bool

    public init(
        actions: [ActionRegistration] = [], tools: [ToolRegistration] = [], channels: Set<String> = [],
        internalActions: [InternalAction] = [], internalTools: [InternalTool] = [],
        controls: [ControlRegistration] = [], controlGuidance: ControlGuidance? = nil, supportsWait: Bool = false
    )
        throws
    {
        guard controlGuidance == nil || !controls.isEmpty else { throw GenerationError.invalidParameters }
        guard
            actions.count + tools.count + controls.count + internalActions.count + internalTools.count <= 128,
            channels.count <= 16
        else { throw GenerationError.limitExceeded }
        let paths = actions.map { $0.path.description } + tools.map(\.path) + controls.map { $0.path.description }
        guard Set(paths).count == paths.count else { throw GenerationError.duplicateAlias }
        let aliases = actions.map(\.alias) + tools.map(\.alias) + controls.map(\.alias)
        guard Set(aliases).count == aliases.count else { throw GenerationError.duplicateAlias }
        guard aliases.allSatisfy({ Self.validName($0) && $0 != "wait" }),
            channels.allSatisfy(Self.validName),
            actions.allSatisfy({
                Self.validName($0.defaultChannel) && $0.path.isValid
            }),
            controls.allSatisfy({ $0.path.isValid }),
            tools.allSatisfy({ Self.validPath($0.path) })
        else { throw GenerationError.invalidParameters }
        for action in actions {
            try Self.validateSchema(required: action.requiredParameters, optional: action.optionalParameters)
        }
        for control in controls {
            try Self.validateSchema(required: control.requiredParameters, optional: control.optionalParameters)
        }
        for tool in tools {
            try Self.validateSchema(required: tool.requiredParameters, optional: tool.optionalParameters)
        }
        for action in internalActions {
            guard Self.validName(action.path.domain), Self.validName(action.path.module),
                Self.validName(action.path.function),
                Self.validName(action.channel)
            else { throw GenerationError.invalidParameters }
            try Self.validateSchema(required: action.requiredParameters, optional: action.optionalParameters)
        }
        for tool in internalTools {
            guard Self.validPath(tool.path) else { throw GenerationError.invalidParameters }
            try Self.validateSchema(required: tool.requiredParameters, optional: tool.optionalParameters)
        }
        self.internalActions = internalActions
        self.internalTools = internalTools
        self.actions = actions
        self.tools = tools
        self.controls = controls
        self.controlGuidance = controlGuidance
        self.supportsWait = supportsWait
        self.channels = channels.union(actions.map(\.defaultChannel)).union(internalActions.map(\.channel))
        guard self.channels.count <= 16 else { throw GenerationError.limitExceeded }
    }

    public func resolveAction(_ alias: String, parameters: [String: String]) throws
        -> ActionCall
    {
        guard let action = actions.first(where: { $0.alias == alias }) else { throw GenerationError.unknownCapability }
        try Self.validate(
            parameters, required: action.requiredParameters, optional: action.optionalParameters,
            ignoringUnknownKeys: true)
        let allowed = action.requiredParameters.union(action.optionalParameters)
        return ActionCall(
            actionPath: action.path, channel: action.defaultChannel,
            parameters: parameters.filter { allowed.contains($0.key) })
    }

    /// Longest single `<wait time/>` pause and the cumulative pause budget of one generation.
    public static let maximumPauseMilliseconds = 60_000
    public static let maximumTotalPauseMilliseconds = 120_000

    /// Validates the registered `wait` self-closing form. `time` is decimal seconds, resolved to milliseconds.
    public func resolvePause(_ parameters: [String: String]) throws -> SchedulingDirective {
        guard supportsWait else { throw GenerationError.unknownCapability }
        guard Set(parameters.keys) == ["time"], let text = parameters["time"], text.utf8.count <= 16,
            let seconds = Self.decimal(text)
        else { throw GenerationError.invalidParameters }
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds >= 1, milliseconds <= Double(Self.maximumPauseMilliseconds) else {
            throw GenerationError.invalidParameters
        }
        return .pause(milliseconds: Int(milliseconds))
    }

    private static func decimal(_ text: String) -> Double? {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return nil }
        return Double(text)
    }

    public func isControl(_ alias: String) -> Bool { controls.contains { $0.alias == alias } }

    public func resolveControl(_ alias: String, parameters: [String: String]) throws -> ControlCall {
        guard let control = controls.first(where: { $0.alias == alias }) else {
            throw GenerationError.unknownCapability
        }
        try Self.validate(
            parameters, required: control.requiredParameters, optional: control.optionalParameters,
            ignoringUnknownKeys: true)
        let allowed = control.requiredParameters.union(control.optionalParameters)
        return ControlCall(
            path: control.path, destination: control.destination,
            parameters: parameters.filter { allowed.contains($0.key) })
    }

    public func resolveTool(_ alias: String, arguments: [String: String], id: String? = nil) throws -> ToolCall {
        guard let tool = tools.first(where: { $0.alias == alias }) else { throw GenerationError.unknownCapability }
        try Self.validate(arguments, required: tool.requiredParameters, optional: tool.optionalParameters)
        guard Self.permitsValues(arguments, definition: tool.definition) else {
            throw GenerationError.invalidParameters
        }
        return ToolCall(id: id ?? UUID().uuidString, toolPath: tool.path, arguments: arguments)
    }

    public func adding(
        internalActions: [InternalAction] = [], internalTools: [InternalTool] = [],
        controls: [ControlRegistration] = [],
        controlGuidance: ControlGuidance? = nil
    ) throws -> Self {
        try Self(
            actions: actions, tools: tools, channels: channels,
            internalActions: self.internalActions + internalActions, internalTools: self.internalTools + internalTools,
            controls: self.controls + controls, controlGuidance: controlGuidance ?? self.controlGuidance,
            supportsWait: supportsWait)
    }

    public func permits(_ call: ActionCall) -> Bool {
        guard channels.contains(call.channel) else { return false }
        return actions.contains {
            $0.path == call.actionPath && $0.defaultChannel == call.channel
                && (try? Self.validate(
                    call.parameters,
                    required: $0.requiredParameters, optional: $0.optionalParameters)) != nil
        }
            || internalActions.contains {
                $0.path == call.actionPath && $0.channel == call.channel
                    && (try? Self.validate(
                        call.parameters,
                        required: $0.requiredParameters, optional: $0.optionalParameters)) != nil
            }
    }

    public func permits(_ call: ControlCall) -> Bool {
        controls.contains {
            $0.path == call.path
                && (try? Self.validate(
                    call.parameters, required: $0.requiredParameters, optional: $0.optionalParameters)) != nil
        }
    }

    public func permits(_ call: ToolCall) -> Bool {
        tools.contains {
            $0.path == call.toolPath
                && (try? Self.validate(
                    call.arguments,
                    required: $0.requiredParameters, optional: $0.optionalParameters)) != nil
                && Self.permitsValues(call.arguments, definition: $0.definition)
        }
            || internalTools.contains {
                $0.path == call.toolPath
                    && (try? Self.validate(
                        call.arguments,
                        required: $0.requiredParameters, optional: $0.optionalParameters)) != nil
            }
    }

    private static func permitsValues(_ arguments: [String: String], definition: NativeToolDefinition?) -> Bool {
        arguments.allSatisfy { name, value in
            guard let allowed = definition?.function.parameters.properties[name]?.enum else { return true }
            return allowed.contains(value)
        }
    }

    static func validPath(_ path: String) -> Bool {
        let segments = path.split(separator: ".", omittingEmptySubsequences: false)
        return segments.count == 3 && segments.allSatisfy { validName(String($0)) && !$0.contains(".") }
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

    static func validate(
        _ values: [String: String], required: Set<String>, optional: Set<String>, ignoringUnknownKeys: Bool = false
    ) throws {
        let keys = Set(values.keys)
        guard required.isSubset(of: keys), ignoringUnknownKeys || keys.isSubset(of: required.union(optional)),
            values.count <= 32, values.allSatisfy({ validName($0.key) })
        else { throw GenerationError.invalidParameters }
    }
}
