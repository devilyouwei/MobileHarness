import FunctionContracts

/// Where a control takes effect: the owning Agent's own state, or another Agent.
public enum ControlDestination: String, Codable, Sendable, Equatable {
    case own = "self"
    case peer
}

/// A control function run by its owning Agent; never scheduled as an Action and never sent to Actions.
public struct ControlRegistration: Sendable {
    public let documentation: CapabilityDocumentation?
    public let alias: String
    public let path: ActionPath
    public let destination: ControlDestination
    public let requiredParameters: Set<String>
    public let optionalParameters: Set<String>
    /// Current-language declaration from which the model-facing documentation is rendered.
    public let declaration: ActionDeclaration
    /// Owner-supplied declaration for a prompt language; prompt text never lives in code.
    public let localized: @Sendable (String) throws -> ActionDeclaration

    public init(
        alias: String, declaration: ActionDeclaration, destination: ControlDestination = .own,
        localized: @escaping @Sendable (String) throws -> ActionDeclaration
    ) {
        self.alias = alias
        self.declaration = declaration
        self.destination = destination
        self.localized = localized
        path = ActionPath(
            domain: declaration.path.domain, module: declaration.path.module, function: declaration.path.function)
        requiredParameters = Set(declaration.parameters.filter(\.required).map(\.name))
        optionalParameters = Set(declaration.parameters.filter { !$0.required }.map(\.name))
        documentation = CapabilityDocumentation(
            doc: declaration.doc,
            parameters: declaration.parameters.map {
                .init(
                    name: $0.name, valueType: .init(rawValue: $0.valueType.rawValue) ?? .string,
                    required: $0.required, description: $0.description, constraints: $0.constraints)
            })
    }
}

/// A validated model request for a control function; it carries no Channel and no execution authority.
public struct ControlCall: Equatable, Sendable {
    public let path: ActionPath
    public let destination: ControlDestination
    public let parameters: [String: String]

    public init(path: ActionPath, destination: ControlDestination = .own, parameters: [String: String] = [:]) {
        self.path = path
        self.destination = destination
        self.parameters = parameters
    }
}
